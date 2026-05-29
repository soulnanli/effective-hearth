--[[
   lib/lru_cache.lua
   ---------------------------------------------------------
   通用 LRU 缓存 (双向链表 + hash 表实现)
   - O(1) get / put / evict_lru / remove
   - 不依赖 Stonehearth, 纯 Lua, 便于复用和单元测试
   ---------------------------------------------------------
   API:
     local LRU = require 'effective_hearth.lib.lru_cache'
     local cache = LRU.new(max_size)
     cache:put(key, value)         -- 插入 (满时淘汰最旧)
     cache:get(key)                -- 命中刷新 last_used 并返回 value, miss 返回 nil
     cache:peek(key)               -- 不刷新 last_used 直接返回 value
     cache:remove(key)             -- 删除
     cache:size()                  -- 当前条目数
     cache:clear()                 -- 清空
     cache:each(fn)                -- 遍历所有 entry, fn(key, value)
   ---------------------------------------------------------
   双向链表约定:
     head = most recent  (刚 put / get 的)
     tail = least recent (容量满时被淘汰)
   ---------------------------------------------------------
]]

local LRU = {}
LRU.__index = LRU

function LRU.new(max_size)
   if type(max_size) ~= 'number' or max_size < 1 then
      error('LRU.new: max_size must be a positive number, got ' .. tostring(max_size))
   end
   return setmetatable({
      _entries  = {},        -- key -> node
      _head     = nil,       -- most recent
      _tail     = nil,       -- least recent
      _size     = 0,
      _max      = max_size,
   }, LRU)
end

-- node 结构:
--   { key = ..., value = ..., prev = node|nil, next = node|nil }

-- ============ 内部链表操作 ============

local function _detach(self, node)
   -- 把 node 从链表里摘出来
   local prev, next_ = node.prev, node.next
   if prev then prev.next = next_ else self._head = next_ end
   if next_ then next_.prev = prev else self._tail = prev end
   node.prev, node.next = nil, nil
end

local function _attach_head(self, node)
   -- 把 node 挂到链表头
   node.prev = nil
   node.next = self._head
   if self._head then self._head.prev = node end
   self._head = node
   if not self._tail then self._tail = node end
end

local function _move_to_head(self, node)
   if self._head == node then return end
   _detach(self, node)
   _attach_head(self, node)
end

-- ============ 公开 API ============

function LRU:get(key)
   local node = self._entries[key]
   if not node then return nil end
   _move_to_head(self, node)
   return node.value
end

function LRU:peek(key)
   local node = self._entries[key]
   if not node then return nil end
   return node.value
end

function LRU:put(key, value)
   local node = self._entries[key]
   if node then
      -- 更新已有
      node.value = value
      _move_to_head(self, node)
      return
   end

   -- 容量满时淘汰最旧
   if self._size >= self._max then
      self:_evict_lru()
   end

   node = { key = key, value = value }
   self._entries[key] = node
   self._size = self._size + 1
   _attach_head(self, node)
end

function LRU:remove(key)
   local node = self._entries[key]
   if not node then return false end
   _detach(self, node)
   self._entries[key] = nil
   self._size = self._size - 1
   return true
end

function LRU:_evict_lru()
   local node = self._tail
   if not node then return nil end
   _detach(self, node)
   self._entries[node.key] = nil
   self._size = self._size - 1
   return node.key, node.value
end

function LRU:size()
   return self._size
end

function LRU:max_size()
   return self._max
end

function LRU:clear()
   self._entries = {}
   self._head = nil
   self._tail = nil
   self._size = 0
end

function LRU:each(fn)
   -- 遍历从 head (最新) 到 tail (最旧)
   -- 注意: 遍历期间不要 put/remove 同一个 cache, 行为未定义
   local node = self._head
   while node do
      local nxt = node.next
      fn(node.key, node.value)
      node = nxt
   end
end

return LRU
