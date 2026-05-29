--[[
   patches/memory_observer.lua
   ---------------------------------------------------------
   目的: 周期性 dump 内存归因数据，定位 OOM 的真凶。
   ---------------------------------------------------------
   使用的游戏 API（来自 binary strings 提取）:
     - radiant:dump_memory_stats          整体内存统计
     - radiant:write_lua_memory_profile   Lua heap 按对象类型归因
       (要求 user_settings: lua.enable_memory_profiler = true)
     - 输出文件: 游戏根目录的 lua_memory_profile_server.txt 和 _client.txt
   ---------------------------------------------------------
   我们做什么:
     1. 启动时检查 lua.enable_memory_profiler 是否开
     2. 每 30s（可 config）调用一次 dump_memory_stats + write_lua_memory_profile
     3. 把 profile 文件改名带时间戳保存到 profiler_output/memory/
        (这样能拿时间序列, 看哪类内存在涨)
   ---------------------------------------------------------
   不确定项 (运行时验证):
     - RPC 是否能从 server-side Lua 直接调 (pcall 包裹兜底)
     - dump_memory_stats 输出粒度
     - 文件名是否真的是 lua_memory_profile_server.txt
   ---------------------------------------------------------
]]

return {
   id          = 'memory_observer',
   description = '周期性 dump 内存归因数据，定位 OOM 真凶',
   default     = true,

   apply = function(ctx)
      local log = ctx.log
      local interval_s   = ctx.cfg.interval_s   or 30
      local save_history = ctx.cfg.save_history
      if save_history == nil then save_history = true end

      -- 校验
      if type(interval_s) ~= 'number' or interval_s < 5 then
         log:error('invalid interval_s=%s, refusing to install', tostring(interval_s))
         error('invalid interval_s')
      end

      -- ============================================================
      -- 启动时检查 lua.enable_memory_profiler
      -- ============================================================
      local mp_enabled = false
      do
         local ok, val = pcall(function()
            -- 注意: lua.enable_memory_profiler 是 global config (在 stonehearth.json
            -- 或 user_settings.json 顶层 lua 子表), 不是 mods.X
            return _host:get_config('lua.enable_memory_profiler')
         end)
         if ok and val == true then
            mp_enabled = true
         end
      end

      if not mp_enabled then
         log:warning('lua.enable_memory_profiler is OFF or not readable')
         log:warning('  → write_lua_memory_profile may produce empty files')
         log:warning('  → enable it in user_settings.json: { "lua": { "enable_memory_profiler": true } }')
         log:warning('  → continuing anyway, will try to dump on schedule')
      else
         log:info('lua.enable_memory_profiler is ON')
      end

      -- ============================================================
      -- 准备输出目录
      -- ============================================================
      -- 游戏根目录是 cwd. profiler_output/ 已经被原版 cpu profiler 用过, 我们建子目录
      -- 不需要 mkdir, 先尝试把文件移过去, 失败就留在原位
      local OUTPUT_SUBDIR = 'profiler_output/memory/'

      -- ============================================================
      -- 计数器 + 时间戳工具
      -- ============================================================
      local stats = {
         dumps_attempted = 0,
         dumps_succeeded = 0,
         dumps_failed = 0,
         saved_files = 0,
      }

      local function ts_str()
         -- 用游戏时间还是 wall clock? 用 wall clock 更直观, 跟 stonehearth.log 时间戳对得上
         -- os.date / os.time 在 stonehearth lua 沙箱里可能不可用; 试一下
         local ok, t = pcall(os.date, '%Y%m%d_%H%M%S')
         if ok and type(t) == 'string' then return t end
         -- fallback: 用 stats 计数 + 简单时间
         return string.format('seq%04d', stats.dumps_attempted)
      end

      -- ============================================================
      -- 文件操作 (保守: 用 io.open, 不可用就降级)
      -- ============================================================
      local function copy_or_rename_file(src, dst)
         -- 先尝试 os.rename (原子操作, 同盘可用)
         local ok, err = pcall(os.rename, src, dst)
         if ok then return true end

         -- 降级: read src, write dst, delete src
         local fr_ok, fr = pcall(io.open, src, 'rb')
         if not fr_ok or not fr then return false, 'open src failed' end
         local data = fr:read('*all')
         fr:close()
         if not data or #data == 0 then return false, 'src empty' end

         local fw_ok, fw = pcall(io.open, dst, 'wb')
         if not fw_ok or not fw then return false, 'open dst failed' end
         fw:write(data)
         fw:close()

         pcall(os.remove, src)
         return true
      end

      local function ensure_dir(path)
         -- io.open(path .. '/.x', 'w') 测试目录是否存在; 失败说明目录不存在
         -- 我们没法 mkdir, 但 profiler_output/ 已经被 cpu profile 创建过, 子目录可能要手动建一次
         -- 简单方案: 试着写一个测试文件, 失败就把文件留在 profiler_output/ 根下
         local test = path .. '__test__'
         local f = io.open(test, 'w')
         if f then
            f:close()
            pcall(os.remove, test)
            return true
         end
         return false
      end

      local subdir_ok = ensure_dir(OUTPUT_SUBDIR)
      if not subdir_ok then
         log:warning('cannot write to %s (does it exist?), falling back to profiler_output/', OUTPUT_SUBDIR)
         OUTPUT_SUBDIR = 'profiler_output/'
      end

      -- ============================================================
      -- 一次 dump
      -- ============================================================
      local function do_dump()
         stats.dumps_attempted = stats.dumps_attempted + 1
         local seq = stats.dumps_attempted
         local stamp = ts_str()

         log:info('dump #%d start (timestamp=%s)', seq, stamp)

         -- 1. dump_memory_stats —— 整体快照, 它会自动 log 到 stonehearth.log (sysinfo 类)
         local stats_ok, stats_err = pcall(function()
            _radiant.call('radiant:dump_memory_stats')
         end)
         if not stats_ok then
            log:warning('  dump_memory_stats RPC failed: %s', tostring(stats_err))
         end

         -- 2. write_lua_memory_profile —— 写出 .txt 文件
         local mp_ok, mp_err = pcall(function()
            _radiant.call('radiant:write_lua_memory_profile')
         end)
         if not mp_ok then
            log:warning('  write_lua_memory_profile RPC failed: %s', tostring(mp_err))
            stats.dumps_failed = stats.dumps_failed + 1
            return
         end

         stats.dumps_succeeded = stats.dumps_succeeded + 1

         -- 3. 把生成的文件改名 (保留时间序列)
         if save_history then
            -- 注意: RPC 是异步的, profile 文件可能要几百ms后才落盘
            -- 我们延迟 1 秒再改名, 用 set_realtime_timer
            radiant.set_realtime_timer('effective_hearth.memory_observer rename', 1000, function()
               local files = {
                  'lua_memory_profile_server.txt',
                  'lua_memory_profile_client.txt',
               }
               for _, src in ipairs(files) do
                  local dst = string.format('%smem_%s_%s', OUTPUT_SUBDIR, stamp,
                     src:gsub('lua_memory_profile_', ''))
                  local ok, err = copy_or_rename_file(src, dst)
                  if ok then
                     stats.saved_files = stats.saved_files + 1
                     log:info('  saved %s -> %s', src, dst)
                  else
                     log:debug('  rename %s skipped: %s', src, tostring(err))
                  end
               end
            end)
         end

         log:info('dump #%d done (succeeded=%d failed=%d saved=%d)',
            seq, stats.dumps_succeeded, stats.dumps_failed, stats.saved_files)
      end

      -- ============================================================
      -- 调度
      -- ============================================================
      radiant.set_realtime_interval('effective_hearth.memory_observer dump',
         interval_s * 1000,
         function()
            local ok, err = pcall(do_dump)
            if not ok then
               log:error('do_dump crashed: %s', tostring(err))
            end
         end
      )

      log:info('installed: interval=%ds, save_history=%s, output_dir=%s',
         interval_s, tostring(save_history), OUTPUT_SUBDIR)
   end,
}
