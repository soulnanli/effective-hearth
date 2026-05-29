--[[
   effective_hearth_server.lua
   ----------------------------------------------------------
   唯一入口。职责：
     1. 读 config
     2. 初始化 logger
     3. 调用 patch_registry 加载/应用 patches/*.lua
     4. 打印启动报告（+/-/! 三种状态）
   ----------------------------------------------------------
   失败模式：任何异常都被 pcall 接住。最坏情况是 0 patches active，
            原版游戏行为完全保留。
   ----------------------------------------------------------
   备注：Stonehearth 顶层入口脚本必须 return 一个 table。
        我们把状态挂到全局 effective_hearth 上，并在末尾 return 它。
]]

-- 全局表必须最早创建，避免后续任何 require 失败导致整个文件中途死掉
effective_hearth = {
   version = '0.1.0',
}

local Log = require 'effective_hearth.lib.log'
local PatchRegistry = require 'effective_hearth.lib.patch_registry'

local function count_table(t)
   if type(t) ~= 'table' then return 0 end
   local n = 0
   for _ in pairs(t) do n = n + 1 end
   return n
end

-- ============================================================
-- 1. 读 config (用 pcall 包裹每个 key，单个失败不会致命)
-- ============================================================

local function read_config()
   local g = radiant.util.get_config
   local function safe_get(key, default)
      local ok, val = pcall(g, key, default)
      if ok then return val else return default end
   end
   return {
      enabled    = safe_get('enabled', true),
      log_level  = safe_get('log_level', 'info'),
      patches    = safe_get('patches', {}) or {},
   }
end

local cfg = read_config()

-- ============================================================
-- 2. 初始化 logger
-- ============================================================

local log = Log.new('effective_hearth', cfg.log_level)
effective_hearth.log = log

-- ============================================================
-- 3. 总开关
-- ============================================================

if not cfg.enabled then
   log:info('disabled by config (mods.effective_hearth.enabled = false)')
   return effective_hearth
end

log:info('booting v%s', effective_hearth.version)
log:info('config: log_level=%s, patches=%d configured',
   cfg.log_level, count_table(cfg.patches))

-- ============================================================
-- 4. 加载 + 应用 patches
-- ============================================================

local registry = PatchRegistry.new(log)
effective_hearth.registry = registry

local patch_files = {
   'astar_observer',
   'astar_max_steps',
   'astar_cache',
   -- 'memory_observer',   -- 暂时禁用：怀疑导致载入存档崩溃，待定位
   -- 后续新增的 patch 在这里加文件名（不带 .lua）
}

local ok, err = pcall(function()
   registry:discover(patch_files)
   registry:apply_all(cfg.patches)
end)

if not ok then
   log:error('registry crashed during boot: %s', tostring(err))
   log:error('all patches skipped, vanilla behavior preserved')
   return effective_hearth
end

-- ============================================================
-- 5. 启动报告
-- ============================================================

local active, total = registry:summary()
log:info('%d/%d patches active', active, total)

return effective_hearth
