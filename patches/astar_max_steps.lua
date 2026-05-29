--[[
   patches/astar_max_steps.lua
   ---------------------------------------------------------
   攻击点: A* pathfinder (vanilla 没有任何 step 上限)
   预期效果:
     - 阻止 OOM (vanilla 实测会撞 14000+ 节点撞内存)
     - 砍掉 ~55% 的 step 数 (大头是不可达搜索的长尾扫图)
     - astar Perfmon 占比预期 54.9% → ~25%
     - 0 假阳性 (实测 solved max=2898, P99=2314, 4000 安全余量 38%)
   ---------------------------------------------------------
   覆盖范围:
     1. AStarSearch:_start_pathfinder
        所有 PathFinderComponent:find_path_to_entity 都走这里
        即 find_path_to_entity / find_path_to_reachable_entity /
           run_to_entity / get_patrol_route / combat_idle / conversation
        ~95% 的 A* 调用
     2. FindTrapInTrappingGrounds:start_thinking
        猎人去检查陷阱
   ---------------------------------------------------------
   不覆盖 (有意为之):
     - PathFinderComponent:get_sync_pathfinder
       已经被 max_distance ≤ 10 限制
     - chase_entity_action
       战斗追击保留 vanilla 行为
   ---------------------------------------------------------
   失败语义 (Q4=A):
     截断时 C++ 自动调原本的 search_exhausted_cb,
     Lua 走 ai:reject('search exhausted') + backoff 重试,
     和 vanilla "找不到路" 行为完全一致
   ---------------------------------------------------------
]]

return {
   id          = 'astar_max_steps',
   description = '限制 A* 寻路最大扩展节点数, 防 OOM 和长尾失败搜索',
   default     = true,

   apply = function(ctx)
      local log = ctx.log
      local max_steps = ctx.cfg.max_steps or 4000

      -- 校验参数
      if type(max_steps) ~= 'number' or max_steps < 100 then
         log:error('invalid max_steps=%s, refusing to install', tostring(max_steps))
         error('invalid max_steps')
      end

      -- ============ Hook 1: AStarSearch (主战场) ============
      local ok_search, AStarSearch = pcall(require, 'stonehearth.components.pathfinder.astar_search')
      if not ok_search or not AStarSearch then
         log:error('cannot require AStarSearch: %s', tostring(AStarSearch))
         error('AStarSearch hook failed')
      end

      local orig_start = AStarSearch._start_pathfinder
      if type(orig_start) ~= 'function' then
         log:error('AStarSearch._start_pathfinder is not a function')
         error('AStarSearch hook failed')
      end

      function AStarSearch:_start_pathfinder(dest)
         local was_existing = self._pathfinder ~= nil
         local rv = orig_start(self, dest)

         -- 仅在新创建 pathfinder 时设上限. 复用既有的不重设, 避免覆盖
         if not was_existing and self._pathfinder then
            local ok, err = pcall(function()
               self._pathfinder:set_max_steps(max_steps)
            end)
            if not ok then
               log:warning('set_max_steps failed on AStarSearch: %s', tostring(err))
            end
         end

         return rv
      end

      log:info('hooked AStarSearch:_start_pathfinder')

      -- ============ Hook 2: FindTrapInTrappingGrounds ============
      local ok_trap, TrapAction = pcall(require, 'stonehearth.ai.actions.trapping.find_trap_in_trapping_grounds_action')
      if not ok_trap or not TrapAction then
         log:warning('cannot require FindTrapInTrappingGrounds, skipping (non-critical): %s',
                     tostring(TrapAction))
      else
         local orig_trap_start = TrapAction.start_thinking
         if type(orig_trap_start) ~= 'function' then
            log:warning('FindTrapInTrappingGrounds.start_thinking is not a function, skipping')
         else
            function TrapAction:start_thinking(ai, entity, args)
               local rv = orig_trap_start(self, ai, entity, args)
               -- 原版在内部创建 pathfinder, 我们 wrap 完之后能拿到 self._pathfinder
               if self._pathfinder then
                  local ok, err = pcall(function()
                     self._pathfinder:set_max_steps(max_steps)
                  end)
                  if not ok then
                     log:warning('set_max_steps failed on FindTrapInTrappingGrounds: %s', tostring(err))
                  end
               end
               return rv
            end
            log:info('hooked FindTrapInTrappingGrounds:start_thinking')
         end
      end

      log:info('installed: max_steps=%d', max_steps)
   end,
}
