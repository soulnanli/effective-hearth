--[[
   patches/_template.lua
   ---------------------------------------------------------
   样板：写新 patch 时复制这个文件，改名（不要以 _ 开头）。
   patch_registry 不会加载下划线前缀的文件。
   ---------------------------------------------------------
]]

return {
   id          = 'example_patch',
   description = '示例：什么也不做',
   default     = false,    -- 新建的实验性 patch 应默认关

   apply = function(ctx)
      local log = ctx.log

      -- 读自己的子配置
      local some_cap = ctx.cfg.some_cap or 100

      -- 包装目标方法
      local target = require 'stonehearth.path.to.some_class'  -- 替换成真实路径
      local original = target.some_method

      function target:some_method(args)
         if args.value > some_cap then
            args.value = some_cap
         end
         return original(self, args)
      end

      log:info('installed: some_cap=%d', some_cap)
   end,
}
