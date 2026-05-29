--[[
   lib/safe_require.lua
   ---------------------------------------------------------
   pcall(require) 包裹，避免一个 patch 文件的语法错误把整个 mod 干死。
   用法:
      local ok, mod_or_err = safe_require('patches.foo')
      if ok then ... else log:error('%s', mod_or_err) end
   ---------------------------------------------------------
]]

return function(modname)
   local ok, mod_or_err = pcall(require, modname)
   if ok then
      return true, mod_or_err
   else
      return false, tostring(mod_or_err)
   end
end
