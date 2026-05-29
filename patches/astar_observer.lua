--[[
   patches/astar_observer.lua
   ---------------------------------------------------------
   目的：observe-only。不修改任何寻路行为，只采集数据：
     1. A* 创建次数（区分首次 vs 重启）
     2. 每次寻路完成 / 耗尽时的 step 数
     3. position-trace 触发的重启次数

   攻击点：
     - AStarSearch:_start_pathfinder  → 创建计数
     - AStarSearch:_on_solved         → 完成 step 分布
     - AStarSearch:_on_exhausted      → 耗尽 step 分布
     - FindPathToEntity:_on_position_changed → 重启计数

   输出：每 N 秒打一份分布报告到 stonehearth.log，便于决定 max_steps。
   ---------------------------------------------------------
   风险：
     - 不调用 set_max_steps，行为完全保留 vanilla
     - get_progress() 是 vanilla 已有 API，调它不引入新副作用
     - 周期 log 可关（report_interval_s = 0）
   ---------------------------------------------------------
]]

-- ============================================================
-- step 数解析
-- ============================================================
-- AStarSearch:get_progress() 返回 C++ pathfinder 的 progress 字符串。
-- 字段（从 binary strings 看）：
--   "steps:N"   累计扩展节点数
--   "open:M"    当前 open set 大小
--   "closed:K"  closed set 大小
--
-- 区分两种 exhausted:
--   open == 0  → A* 真的扫完整张可达图（"不可达"确定结论）
--   open  > 0  → 还有候选没扩展（如果是被 max_steps 截断会留 open>0；
--                                vanilla 状态不应该出现）
local function parse_progress(progress_str)
   if type(progress_str) ~= 'string' then return nil, nil, nil end
   local steps  = string.match(progress_str, 'steps:%s*(%d+)')
   local open   = string.match(progress_str, 'open:%s*(%d+)')
   local closed = string.match(progress_str, 'closed:%s*(%d+)')
   return tonumber(steps), tonumber(open), tonumber(closed)
end

-- ============================================================
-- 直方图（log10 分桶）
-- ============================================================
-- 桶: [0,10) [10,100) [100,1k) [1k,10k) [10k,100k) [100k,+)
local BUCKETS = { 10, 100, 1000, 10000, 100000 }
local BUCKET_LABELS = {
   '[0,10)', '[10,100)', '[100,1k)', '[1k,10k)', '[10k,100k)', '[100k,+)'
}

local Histogram = {}
Histogram.__index = Histogram

function Histogram.new()
   return setmetatable({
      counts = { 0, 0, 0, 0, 0, 0 },
      total = 0,
      sum = 0,
      max = 0,
      samples = {},  -- 用于算分位数（保留最近 1000 个）
      _max_samples = 1000,
   }, Histogram)
end

function Histogram:add(v)
   if type(v) ~= 'number' or v < 0 then return end
   self.total = self.total + 1
   self.sum = self.sum + v
   if v > self.max then self.max = v end

   -- 桶
   local bucket = #BUCKETS + 1
   for i, threshold in ipairs(BUCKETS) do
      if v < threshold then bucket = i; break end
   end
   self.counts[bucket] = self.counts[bucket] + 1

   -- 样本（环形覆盖）
   if #self.samples < self._max_samples then
      table.insert(self.samples, v)
   else
      -- 简单覆盖：随机替换。避免持续增长。
      local idx = math.random(1, self._max_samples)
      self.samples[idx] = v
   end
end

function Histogram:percentile(p)
   if #self.samples == 0 then return 0 end
   local sorted = {}
   for _, v in ipairs(self.samples) do table.insert(sorted, v) end
   table.sort(sorted)
   local idx = math.ceil(#sorted * p / 100)
   if idx < 1 then idx = 1 end
   if idx > #sorted then idx = #sorted end
   return sorted[idx]
end

function Histogram:format()
   if self.total == 0 then
      return '(no samples)'
   end
   local lines = {}
   table.insert(lines, string.format('  total=%d  sum=%d  avg=%.0f  max=%d',
      self.total, self.sum, self.sum / self.total, self.max))
   table.insert(lines, string.format('  P50=%d  P90=%d  P95=%d  P99=%d',
      self:percentile(50), self:percentile(90), self:percentile(95), self:percentile(99)))
   for i, c in ipairs(self.counts) do
      if c > 0 then
         local pct = c / self.total * 100
         table.insert(lines, string.format('  %-12s  %6d  (%.1f%%)', BUCKET_LABELS[i], c, pct))
      end
   end
   return table.concat(lines, '\n')
end

function Histogram:reset()
   self.counts = { 0, 0, 0, 0, 0, 0 }
   self.total = 0
   self.sum = 0
   self.max = 0
   self.samples = {}
end

-- ============================================================
-- patch 入口
-- ============================================================

return {
   id          = 'astar_observer',
   description = 'observe-only: 采集 A* 寻路 step 数 + 重启次数分布',
   default     = false,  -- P3 阶段不再需要, 想用时改 true 或 cfg 里 enable

   apply = function(ctx)
      local log = ctx.log
      local report_interval_s = ctx.cfg.report_interval_s or 60
      local track_per_entity  = ctx.cfg.track_per_entity or false

      -- ============ 计数器 ============
      local stats = {
         pf_started = 0,             -- AStarSearch:_start_pathfinder 被调用次数（含创建首次 + 复用 + 重启首次）
         pf_created_first = 0,       -- 实际 create_astar_path_finder 被调用（首次创建 pathfinder 实例）
         pf_destination_added = 0,   -- 复用既有 pathfinder（add_destination 而不创建新的）
         pf_solved = 0,
         pf_exhausted = 0,
         pos_trace_fired = 0,        -- _on_position_changed 被回调次数
         pos_trace_restart = 0,      -- 实际触发了重启（distance > 2）
         pos_trace_skipped = 0,      -- 被回调但 distance <= 2
      }

      local solved_steps         = Histogram.new()
      local exhausted_open0      = Histogram.new()  -- 真扫完整张图（不可达确定）
      local exhausted_open_left  = Histogram.new()  -- open set 还有候选（异常或被截断）

      -- 周期报告需要"上次报告时的快照"，算增量
      local last_snapshot
      local function snapshot_stats()
         local s = {}
         for k, v in pairs(stats) do s[k] = v end
         return s
      end
      last_snapshot = snapshot_stats()

      -- ============ wrap AStarSearch ============
      local ok_search, AStarSearch = pcall(require, 'stonehearth.components.pathfinder.astar_search')
      if not ok_search then
         log:error('cannot require AStarSearch: %s', tostring(AStarSearch))
         return
      end

      -- _start_pathfinder
      local orig_start = AStarSearch._start_pathfinder
      function AStarSearch:_start_pathfinder(dest)
         stats.pf_started = stats.pf_started + 1

         local was_existing = self._pathfinder ~= nil
         local rv = orig_start(self, dest)

         if was_existing then
            stats.pf_destination_added = stats.pf_destination_added + 1
         else
            stats.pf_created_first = stats.pf_created_first + 1
         end
         return rv
      end

      -- _on_solved
      local orig_solved = AStarSearch._on_solved
      function AStarSearch:_on_solved(path)
         stats.pf_solved = stats.pf_solved + 1
         if self._pathfinder then
            local progress = self._pathfinder:get_progress()
            local steps, open, closed = parse_progress(progress)
            if steps then solved_steps:add(steps) end
         end
         return orig_solved(self, path)
      end

      -- _on_exhausted
      local orig_exhausted = AStarSearch._on_exhausted
      function AStarSearch:_on_exhausted()
         stats.pf_exhausted = stats.pf_exhausted + 1
         if self._pathfinder then
            local progress = self._pathfinder:get_progress()
            local steps, open, closed = parse_progress(progress)
            if steps then
               -- 区分两种 exhausted:
               --   open == 0: A* 真的扫完整张可达图，结论"不可达"是确定的
               --   open  > 0: 还有候选没扩展（vanilla 不应该发生；如果发生说明被截断）
               if open == nil or open == 0 then
                  exhausted_open0:add(steps)
               else
                  exhausted_open_left:add(steps)
               end
            end
         end
         return orig_exhausted(self)
      end

      log:info('hooked AStarSearch (start/solved/exhausted)')

      -- ============ wrap FindPathToEntity ============
      local ok_fpe, FindPathToEntity = pcall(require, 'stonehearth.ai.actions.find_path_to_entity')
      if ok_fpe and FindPathToEntity._on_position_changed then
         local orig_pos = FindPathToEntity._on_position_changed
         function FindPathToEntity:_on_position_changed(ai)
            stats.pos_trace_fired = stats.pos_trace_fired + 1

            -- 在调用原版前快照位置，原版执行后看是否触发了重启
            -- 重启的判定依据原版逻辑：distance > 2 才重启
            -- 我们用一个简单的方式：观察原版调用前后 self._location 是否被改了
            local before_loc = self._location
            local rv = orig_pos(self, ai)
            local after_loc = self._location

            if before_loc ~= after_loc then
               stats.pos_trace_restart = stats.pos_trace_restart + 1
            else
               stats.pos_trace_skipped = stats.pos_trace_skipped + 1
            end
            return rv
         end
         log:info('hooked FindPathToEntity:_on_position_changed')
      else
         log:warning('cannot require FindPathToEntity, position-trace stats disabled: %s',
            tostring(FindPathToEntity))
      end

      -- ============ 周期报告 ============
      if report_interval_s > 0 then
         radiant.set_realtime_interval('effective_hearth.astar_observer report',
            report_interval_s * 1000,
            function()
               local s = stats
               local prev = last_snapshot

               -- 增量
               local d = {}
               for k, v in pairs(s) do d[k] = v - (prev[k] or 0) end

               log:info('==== astar observer report (last %ds) ====', report_interval_s)
               log:info('A* creation:')
               log:info('  _start_pathfinder calls : %d (+%d)', s.pf_started, d.pf_started)
               log:info('  new pathfinder created  : %d (+%d)', s.pf_created_first, d.pf_created_first)
               log:info('  destination reused      : %d (+%d)', s.pf_destination_added, d.pf_destination_added)
               log:info('A* outcome:')
               log:info('  solved                  : %d (+%d)', s.pf_solved, d.pf_solved)
               log:info('  exhausted               : %d (+%d)', s.pf_exhausted, d.pf_exhausted)
               log:info('Position-trace restarts:')
               log:info('  trace fired             : %d (+%d)', s.pos_trace_fired, d.pos_trace_fired)
               log:info('  actual restart          : %d (+%d)', s.pos_trace_restart, d.pos_trace_restart)
               log:info('  skipped (within 2)      : %d (+%d)', s.pos_trace_skipped, d.pos_trace_skipped)
               if s.pos_trace_fired > 0 then
                  local rate = s.pos_trace_restart / s.pos_trace_fired * 100
                  log:info('  restart rate            : %.1f%%', rate)
               end
               log:info('Step distribution (solved):')
               for line in string.gmatch(solved_steps:format(), '[^\n]+') do log:info('%s', line) end
               log:info('Step distribution (exhausted, open=0 = truly unreachable):')
               for line in string.gmatch(exhausted_open0:format(), '[^\n]+') do log:info('%s', line) end
               log:info('Step distribution (exhausted, open>0 = had candidates left):')
               for line in string.gmatch(exhausted_open_left:format(), '[^\n]+') do log:info('%s', line) end
               log:info('==== end report ====')

               last_snapshot = snapshot_stats()
            end
         )
         log:info('reporting every %ds', report_interval_s)
      else
         log:info('periodic reporting disabled (report_interval_s=0)')
      end

      log:info('installed (observe-only, no behavior changes)')
   end,
}
