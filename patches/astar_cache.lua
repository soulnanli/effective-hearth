--[[
   patches/astar_cache.lua
   ---------------------------------------------------------
   A* LRU 缓存 — P3 主优化
   ---------------------------------------------------------
   设计文档: ../P3_ANALYSIS.html  (9 个 Q 决策记录)

   Hook 点: stonehearth.ai.actions.find_path_to_entity._start_pathfinder
   覆盖率: ~80-90% server-side 寻路

   核心机制:
     - key = (start_chunk_16, dest_chunk_16, entity_uri)
     - LRU 容量 1000, 双向链表 O(1)
     - TTL 60s + 5% 探索 + abort evict
     - shadow / live 双模式 (cfg 切换)
     - 三段式补段 (≤8 容差 / 8-32 补段 / >32 fallback)
   ---------------------------------------------------------
   配置:
     mode             = "shadow" | "live" | "disabled"  (默认 shadow)
     chunk_size       = 16
     max_entries      = 1000
     ttl_ms           = 60000
     explore_rate     = 0.05
     refresh_threshold= 0.9    -- 探索 new_path < cached*这个 才替换
     short_path_min   = 30     -- path 长度小于此值视为短 path, 不缓存/不命中
     report_interval_s= 60
   ---------------------------------------------------------
]]

return {
   id          = 'astar_cache',
   description = 'A* LRU 缓存, 减少重复寻路的 CPU 开销',
   default     = true,

   apply = function(ctx)
      local log = ctx.log
      local cfg = ctx.cfg

      -- ============ 1. 解析配置 ============
      local mode             = cfg.mode or 'live'  -- shadow 验证已通过, 默认 live
      local chunk_size       = cfg.chunk_size or 16
      local max_entries      = cfg.max_entries or 1000
      local ttl_ms           = cfg.ttl_ms or 60000
      local explore_rate     = cfg.explore_rate or 0.05
      local refresh_threshold= cfg.refresh_threshold or 0.9
      local short_path_min   = cfg.short_path_min or 30
      local report_interval_s= cfg.report_interval_s or 300  -- 默认 5 分钟一次, 减少 log spam

      -- 校验
      if mode ~= 'shadow' and mode ~= 'live' and mode ~= 'disabled' then
         log:error('invalid mode=%s, must be shadow/live/disabled', tostring(mode))
         error('invalid mode')
      end
      if mode == 'disabled' then
         log:info('disabled by config, no hook installed')
         return
      end

      -- ============ 2. 加载依赖 ============
      local LRU = require 'effective_hearth.lib.lru_cache'
      local cache = LRU.new(max_entries)

      local ok_action, FindPathToEntity = pcall(require, 'stonehearth.ai.actions.find_path_to_entity')
      if not ok_action or type(FindPathToEntity) ~= 'table' then
         log:error('cannot require FindPathToEntity: %s', tostring(FindPathToEntity))
         error('FindPathToEntity hook failed')
      end
      local orig_start_pathfinder = FindPathToEntity._start_pathfinder
      if type(orig_start_pathfinder) ~= 'function' then
         log:error('FindPathToEntity._start_pathfinder is not a function')
         error('FindPathToEntity hook failed')
      end

      -- 用于 abort evict 的反查表 (path 引用 -> key, weak key 防泄漏)
      local path_to_key = setmetatable({}, { __mode = 'k' })

      -- ============ 3. 工具函数 ============

      local function chunk_id(point, size)
         if not point then return 'nil' end
         return string.format('%d_%d_%d',
            math.floor(point.x / size),
            math.floor(point.y / size),
            math.floor(point.z / size))
      end

      local function make_key(start_loc, dest_entity, entity)
         if not start_loc or not dest_entity or not entity then return nil end
         local dest_loc
         local ok, err = pcall(function()
            dest_loc = dest_entity:get_component('mob') and
                       dest_entity:get_component('mob'):get_world_grid_location()
            if not dest_loc then
               -- fallback: 直接读 entity 的 grid location
               dest_loc = radiant.entities.get_world_grid_location(dest_entity)
            end
         end)
         if not ok or not dest_loc then return nil end

         local uri = entity.get_uri and entity:get_uri() or 'unknown'
         return string.format('%s|%s|%s',
            chunk_id(start_loc, chunk_size),
            chunk_id(dest_loc, chunk_size),
            uri)
      end

      -- 距离计算 (曼哈顿, 跟 A* 一致)
      local function manhattan(p1, p2)
         if not p1 or not p2 then return math.huge end
         return math.abs(p1.x - p2.x) + math.abs(p1.y - p2.y) + math.abs(p1.z - p2.z)
      end

      -- ============ 4. 统计计数器 ============

      local stats = {
         total          = 0,
         lookup_hit     = 0,    -- 找到 entry 且未过期
         lookup_miss    = 0,
         lookup_expired = 0,    -- 找到但 TTL 过期
         hit_direct     = 0,    -- 直接命中 (距离 ≤8)
         hit_with_tail  = 0,    -- 补段命中 (8-32, 第一版未实现, 占位)
         hit_explore    = 0,    -- 5% 探索强制 miss
         hit_short_path = 0,    -- 短 path 主动 miss
         hit_dist_fail  = 0,    -- 距离 >32 失败 fallback
         shadow_would_hit = 0,
         shadow_would_miss = 0,
         insert         = 0,
         evict_lru      = 0,    -- LRU 容量触发的淘汰 (隐式, 在 put 内发生)
         evict_ttl      = 0,
         evict_abort    = 0,
         shortcut_found = 0,
         cached_dist_sum   = 0,  -- 用于平均
         vanilla_dist_sum  = 0,
         consistency_match = 0,  -- shadow 阶段 cached/vanilla 一致的次数
         consistency_total = 0,
      }

      local function reset_stats_delta()
         -- 60s 报告时记录 delta, 这里 placeholder
      end

      -- ============ 5. 报告输出 ============

      local last_stats_snapshot = {}
      for k, v in pairs(stats) do last_stats_snapshot[k] = v end

      local function snapshot_delta()
         local delta = {}
         for k, v in pairs(stats) do
            delta[k] = v - (last_stats_snapshot[k] or 0)
            last_stats_snapshot[k] = v
         end
         return delta
      end

      local function emit_report()
         local delta = snapshot_delta()

         log:info('==== astar_cache %s report (last %ds) ====', mode, report_interval_s)
         log:info('Lookup:')
         log:info('  total            : %d (+%d)', stats.total, delta.total)
         log:info('  lookup_hit       : %d (+%d)', stats.lookup_hit, delta.lookup_hit)
         log:info('  lookup_miss      : %d (+%d)', stats.lookup_miss, delta.lookup_miss)
         log:info('  lookup_expired   : %d (+%d)', stats.lookup_expired, delta.lookup_expired)

         if stats.total > 0 then
            local hit_rate = stats.lookup_hit / stats.total * 100
            log:info('  hit_rate         : %.1f%%', hit_rate)
         end

         if mode == 'live' then
            log:info('Outcome (live):')
            log:info('  hit_direct       : %d (+%d)', stats.hit_direct, delta.hit_direct)
            log:info('  hit_with_tail    : %d (+%d)', stats.hit_with_tail, delta.hit_with_tail)
            log:info('  hit_explore      : %d (+%d)', stats.hit_explore, delta.hit_explore)
            log:info('  hit_short_path   : %d (+%d)', stats.hit_short_path, delta.hit_short_path)
            log:info('  hit_dist_fail    : %d (+%d)', stats.hit_dist_fail, delta.hit_dist_fail)
            log:info('  evict_abort      : %d (+%d)', stats.evict_abort, delta.evict_abort)
            log:info('  shortcut_found   : %d (+%d)', stats.shortcut_found, delta.shortcut_found)
         else
            log:info('Outcome (shadow):')
            log:info('  shadow_would_hit : %d (+%d)', stats.shadow_would_hit, delta.shadow_would_hit)
            log:info('  shadow_would_miss: %d (+%d)', stats.shadow_would_miss, delta.shadow_would_miss)
            if stats.consistency_total > 0 then
               log:info('  consistency      : %d/%d (%.1f%%)',
                  stats.consistency_match, stats.consistency_total,
                  stats.consistency_match / stats.consistency_total * 100)
            end
            if stats.consistency_total > 0 then
               log:info('  cached_dist avg  : %.1f', stats.cached_dist_sum / stats.consistency_total)
               log:info('  vanilla_dist avg : %.1f', stats.vanilla_dist_sum / stats.consistency_total)
            end
         end

         log:info('Cache state:')
         log:info('  size             : %d / %d', cache:size(), max_entries)
         log:info('  evict_ttl        : %d (+%d)', stats.evict_ttl, delta.evict_ttl)
         log:info('  insert           : %d (+%d)', stats.insert, delta.insert)
         log:info('==== end report ====')
      end

      -- ============ 6. 核心: lookup 和 insert ============

      local function lookup(key)
         stats.total = stats.total + 1
         if not key then
            stats.lookup_miss = stats.lookup_miss + 1
            return nil
         end
         local entry = cache:get(key)
         if not entry then
            stats.lookup_miss = stats.lookup_miss + 1
            return nil
         end

         -- TTL 检查
         local now = radiant.gamestate.now()
         if ttl_ms > 0 and (now - entry.created_at) > ttl_ms then
            cache:remove(key)
            stats.lookup_expired = stats.lookup_expired + 1
            stats.evict_ttl = stats.evict_ttl + 1
            stats.lookup_miss = stats.lookup_miss + 1
            return nil
         end

         entry.last_used_at = now
         stats.lookup_hit = stats.lookup_hit + 1
         return entry
      end

      local function insert(key, path)
         if not key or not path then return end
         local now = radiant.gamestate.now()
         local entry = {
            path         = path,
            finish_point = path:get_finish_point(),
            path_length  = path:get_path_length(),
            created_at   = now,
            last_used_at = now,
         }
         cache:put(key, entry)
         path_to_key[path] = key
         stats.insert = stats.insert + 1
      end

      -- ============ 7. Hook FindPathToEntity._start_pathfinder ============
      -- 完全重写而非 wrap, 因为要在 cache 命中时模拟 on_success
      -- 但保留对 orig_start_pathfinder 的引用作为 fallback

      -- forward declare (Lua 局部函数互相引用需要先声明)
      local do_cache_hit
      local start_with_capture

      function FindPathToEntity:_start_pathfinder(ai)
         -- 防御: 缺关键字段时直接 return, 不调 vanilla
         -- (vanilla 的 _start_pathfinder line 60-61 会 assert _location/_destination,
         --  我们走到这里说明 cache hit 已经清理过状态, 不应再启动新 pathfinder)
         if not self._location or not self._destination or not self._entity then
            return
         end

         local key = make_key(self._location, self._destination, self._entity)
         if not key then
            -- key 算不出来 (例如 destination 在世界外), 走 vanilla.
            -- 此时 _location/_destination 都还在 (上面已 check), 调 vanilla 安全.
            return orig_start_pathfinder(self, ai)
         end

         self._eh_cache_key = key  -- 保存到实例上, 便于 abort 时反查

         local entry = lookup(key)
         local should_explore = entry and explore_rate > 0 and math.random() < explore_rate

         -- ===== 命中分支 (仅 live 模式) =====
         if mode == 'live' and entry and not should_explore then
            -- Q2 短 path 保护
            if entry.path_length < short_path_min then
               stats.hit_short_path = stats.hit_short_path + 1
               -- 走 vanilla, 不返回缓存
            else
               -- Q1 三段式: 距离校验
               local dest_loc = radiant.entities.get_world_grid_location(self._destination)
               local dist = manhattan(dest_loc, entry.finish_point)

               if dist <= 8 then
                  -- ≤8 容差: 直接复用, 让 vanilla follow_path arrived 容差吸收
                  stats.hit_direct = stats.hit_direct + 1
                  return do_cache_hit(self, ai, entry.path)
               elseif dist <= 32 then
                  -- 8-32 补段: 第一版未实现, 暂时 fallback (避免引入未测试代码)
                  -- TODO P3.1: 实现微型 A* 补段
                  stats.hit_dist_fail = stats.hit_dist_fail + 1
                  -- fallthrough to vanilla
               else
                  -- >32 距离失败
                  stats.hit_dist_fail = stats.hit_dist_fail + 1
                  -- fallthrough to vanilla
               end
            end
         end

         -- ===== shadow 分支记录 =====
         if mode == 'shadow' and entry then
            stats.shadow_would_hit = stats.shadow_would_hit + 1
         elseif mode == 'shadow' then
            stats.shadow_would_miss = stats.shadow_would_miss + 1
         end

         -- ===== 探索分支 =====
         if mode == 'live' and entry and should_explore then
            stats.hit_explore = stats.hit_explore + 1
         end

         -- ===== MISS / shadow / 探索: 走 vanilla 并捕获结果 =====
         return start_with_capture(self, ai, key, entry)
      end

      -- 命中时模拟 on_success 流程
      -- 用 set_realtime_timer(0,...) 推到下一帧, 避免 reentrancy
      do_cache_hit = function(self, ai, path)
         radiant.set_realtime_timer('astar_cache hit', 0, function()
            -- 必须再次检查状态, 因为是异步执行
            if not self._thinking then return end
            if not self._destination or not self._destination:is_valid() then return end

            self._search_exhausted_count = 0
            self:_cleanup()

            -- 关键: 也要销毁 vanilla start_thinking 调度的 wait_time timer,
            -- 否则它后续 fire 时会调 _start_pathfinder, 但我们已经把 _destination
            -- 设为 nil, 导致 vanilla 的 assert 失败 (find_path_to_entity.lua:61).
            if self._timer then
               local ok = pcall(function() self._timer:destroy() end)
               self._timer = nil
            end

            self._destination = nil

            if self._ready then
               local ok = pcall(function() ai:clear_think_output() end)
               if not ok then return end
            end
            pcall(function() ai:set_think_output({ path = path }) end)
         end)
      end

      -- MISS 时走 vanilla, 但内联实现以便 wrap callbacks 抓 path 存 cache
      start_with_capture = function(self, ai, key, shadow_entry)
         -- 注: 不能直接 wrap vanilla _start_pathfinder, 因为 on_success/on_exhausted
         -- 是它内部的 closure. 这里复制 vanilla 代码并加我们的 hook.

         assert(self._location)
         assert(self._destination)

         local on_success = function(path)
            if not self._thinking then return end

            -- ===== 我们的 hook: 学习这条 path =====
            if path then
               local cached_dist = shadow_entry and shadow_entry.path_length or 0
               local new_dist = path:get_path_length()

               if mode == 'shadow' then
                  -- shadow: 学习 + 一致性统计
                  if shadow_entry then
                     stats.consistency_total = stats.consistency_total + 1
                     stats.cached_dist_sum = stats.cached_dist_sum + cached_dist
                     stats.vanilla_dist_sum = stats.vanilla_dist_sum + new_dist
                     local diff_ratio = math.abs(cached_dist - new_dist) /
                                        math.max(new_dist, 1)
                     if diff_ratio < 0.1 then
                        stats.consistency_match = stats.consistency_match + 1
                     end
                  end
                  -- shadow 永远存入 cache
                  if new_dist >= short_path_min then
                     insert(key, path)
                  end
               else  -- live
                  if shadow_entry then
                     -- live + 探索: 比较新旧, 决定是否替换
                     if new_dist < cached_dist * refresh_threshold then
                        insert(key, path)
                        stats.shortcut_found = stats.shortcut_found + 1
                        log:info('shortcut found: %d → %d', cached_dist, new_dist)
                     else
                        -- 还是最优, 重置 created_at 避免紧接着被 TTL 强制刷
                        shadow_entry.created_at = radiant.gamestate.now()
                     end
                  else
                     -- live + miss: 正常学习
                     if new_dist >= short_path_min then
                        insert(key, path)
                     end
                  end
               end
            end

            -- ===== 以下复制 vanilla on_success 流程 =====
            self._search_exhausted_count = 0
            self:_cleanup()
            self._destination = nil
            if self._ready then
               ai:clear_think_output()
            end
            ai:set_think_output({ path = path })
         end

         local on_exhausted = function()
            self._search_exhausted_count = self._search_exhausted_count + 1
            ai:reject('search exhausted looking for entity!')
         end

         if not self._destination:is_valid() then
            on_exhausted()
            return
         end

         self._pathfinder = self._entity:add_component('stonehearth:pathfinder')
                                          :find_path_to_entity(self._location,
                                                               self._destination,
                                                               on_success,
                                                               on_exhausted)
         self:_start_debug_timer()

         if not self._is_future then
            self._position_trace = radiant.entities.trace_grid_location(self._entity, 'path restart')
                                                      :on_changed(function()
                                                         self:_on_position_changed(ai)
                                                      end)
         end
      end

      -- ============ 8. Abort hook (防死循环) ============
      -- 这部分目前简化处理: 不 hook follow_path_action 的 abort
      -- 因为 hook 它需要进 cpp boundary, 复杂度大
      -- 第一版依赖: TTL 60s 兜底 + 5% 探索发现失效
      -- 如果实际跑下来 abort-induced 死循环明显, 再加这个 hook

      -- ============ 9. 周期性报告 ============

      radiant.set_realtime_interval('astar_cache report', report_interval_s * 1000, function()
         pcall(emit_report)
      end)

      -- ============ 10. 安装报告 ============
      log:info('hooked FindPathToEntity:_start_pathfinder')
      log:info('mode=%s chunk_size=%d max_entries=%d ttl_ms=%d explore_rate=%.2f',
         mode, chunk_size, max_entries, ttl_ms, explore_rate)
      log:info('installed (mode=%s)', mode)
   end,
}
