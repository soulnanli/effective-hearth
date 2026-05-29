--[[
   lib/log.lua
   ---------------------------------------------------------
   绕过 radiant.log.create_logger 的 category-level 过滤，
   直接用 radiant.log.write 写到 stonehearth.log。
   这样不管玩家是否调过 logging.log_level，info/warning/error
   都能稳定打出来。
   ---------------------------------------------------------
   level 数值（参考 radiant/modules/log.lua）:
      0 = ALWAYS, 1 = ERROR, 3 = WARNING, 5 = INFO, 7 = DEBUG
   我们用 ALWAYS (0) 写 info 级别消息，确保一定可见。
   ---------------------------------------------------------
]]

local Log = {}
Log.__index = Log

local USER_LEVELS = {
   debug   = 1,
   info    = 2,
   warning = 3,
   error   = 4,
}

function Log.new(category, user_level_str)
   local self = setmetatable({}, Log)
   self._category = category
   self._user_level = USER_LEVELS[user_level_str] or USER_LEVELS.info
   self._prefix = '[' .. category .. '] '
   return self
end

function Log:child(suffix)
   local sub = setmetatable({}, Log)
   sub._category = self._category
   sub._user_level = self._user_level
   sub._prefix = '[' .. self._category .. '.' .. suffix .. '] '
   return sub
end

local function safe_format(fmt, ...)
   if select('#', ...) == 0 then
      return tostring(fmt)
   end
   local ok, s = pcall(string.format, fmt, ...)
   if ok then return s end
   return tostring(fmt) .. ' [format error]'
end

function Log:_write(radiant_level, fmt, ...)
   local msg = self._prefix .. safe_format(fmt, ...)
   -- radiant.log.write 会再 format 一次，所以我们把 msg 当成"最终字符串"
   -- 用 '%s' 占位，避免 msg 内残留的 % 被误解
   radiant.log.write(self._category, 0, '%s', msg)
end

function Log:debug(fmt, ...)
   if self._user_level > USER_LEVELS.debug then return end
   self:_write(7, fmt, ...)
end

function Log:info(fmt, ...)
   if self._user_level > USER_LEVELS.info then return end
   self:_write(5, fmt, ...)
end

function Log:warning(fmt, ...)
   if self._user_level > USER_LEVELS.warning then return end
   self:_write(3, fmt, ...)
end

function Log:error(fmt, ...)
   self:_write(1, fmt, ...)
end

return Log
