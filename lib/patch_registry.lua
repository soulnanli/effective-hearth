--[[
   lib/patch_registry.lua
   ---------------------------------------------------------
   Patch 加载/应用器。
     - discover(filenames): 用 safe_require 把每个 patch 文件加载进来
     - apply_all(cfg.patches): 对每个加载成功的 patch:
         决定 enabled (cfg 优先 > patch.default)
         enabled 则 pcall(patch.apply, ctx)
         失败隔离: 单 patch 失败不影响其他
     - summary(): 返回 (active_count, total_count)
   ---------------------------------------------------------
   patch 模块必须 return 一个 table:
     {
        id          = string,             -- 唯一标识
        description = string,             -- 一句话描述
        default     = boolean,            -- 缺省是否启用
        apply       = function(ctx),      -- 安装函数
     }
   ctx = {
     log = logger,    -- 已经 :child(id) 的 logger
     cfg = table,     -- 该 patch 的子配置 (不含 enabled)
   }
   ---------------------------------------------------------
]]

local safe_require = require 'effective_hearth.lib.safe_require'

local PatchRegistry = {}
PatchRegistry.__index = PatchRegistry

function PatchRegistry.new(log)
   return setmetatable({
      _log = log,
      _patches = {},  -- list of { module, status }; status: 'loaded'|'apply_failed'|'active'|'disabled'
   }, PatchRegistry)
end

-- 检查 patch 模块的字段是否合法
local function validate_patch(mod)
   if type(mod) ~= 'table' then
      return false, 'module did not return a table'
   end
   if type(mod.id) ~= 'string' or #mod.id == 0 then
      return false, 'missing or empty id'
   end
   if type(mod.description) ~= 'string' then
      return false, 'missing description'
   end
   if type(mod.default) ~= 'boolean' then
      return false, 'missing default (boolean)'
   end
   if type(mod.apply) ~= 'function' then
      return false, 'missing apply (function)'
   end
   return true
end

-- 加载阶段: 把 patch 文件 require 进来, 不调用 apply
function PatchRegistry:discover(filenames)
   for _, fn in ipairs(filenames) do
      -- 跳过下划线开头 (template 等)
      if fn:sub(1, 1) == '_' then
         self._log:debug('skip %s (underscore prefix)', fn)
      else
         local modpath = 'effective_hearth.patches.' .. fn
         local ok, mod = safe_require(modpath)
         if not ok then
            self._log:error('!load %s: %s', fn, mod)
         else
            local valid, why = validate_patch(mod)
            if not valid then
               self._log:error('!validate %s: %s', fn, why)
            else
               -- 检查 id 唯一
               local dup = false
               for _, entry in ipairs(self._patches) do
                  if entry.module.id == mod.id then
                     self._log:error('!duplicate id %s (from %s)', mod.id, fn)
                     dup = true
                     break
                  end
               end
               if not dup then
                  table.insert(self._patches, { module = mod, status = 'loaded' })
                  self._log:debug('loaded %s (id=%s)', fn, mod.id)
               end
            end
         end
      end
   end
end

-- 应用阶段: 对每个已加载的 patch 决定 enabled 然后 apply
function PatchRegistry:apply_all(cfg_patches)
   cfg_patches = cfg_patches or {}

   for _, entry in ipairs(self._patches) do
      local mod = entry.module
      local id = mod.id
      local pcfg = cfg_patches[id] or {}

      -- enabled 决议: cfg 中显式存在则用 cfg, 否则用 patch.default
      local enabled
      if pcfg.enabled ~= nil then
         enabled = pcfg.enabled
      else
         enabled = mod.default
      end

      if not enabled then
         self._log:info('  - %s (disabled)', id)
         entry.status = 'disabled'
      else
         -- 派生子 logger, 构造 ctx
         local sub_log = self._log:child(id)
         local sub_cfg = {}
         for k, v in pairs(pcfg) do
            if k ~= 'enabled' then sub_cfg[k] = v end
         end

         local ctx = {
            log = sub_log,
            cfg = sub_cfg,
         }

         local ok, err = pcall(mod.apply, ctx)
         if ok then
            self._log:info('  + %s', id)
            entry.status = 'active'
         else
            self._log:error('  ! %s failed: %s', id, tostring(err))
            entry.status = 'apply_failed'
         end
      end
   end
end

function PatchRegistry:summary()
   local active = 0
   for _, entry in ipairs(self._patches) do
      if entry.status == 'active' then active = active + 1 end
   end
   return active, #self._patches
end

return PatchRegistry
