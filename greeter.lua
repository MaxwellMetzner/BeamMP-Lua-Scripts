------------------------------------------------------------------------
-- BeamMP Server Plugin – Auto-Greeter
--
-- Announces "Hello <name>!" to all players when someone joins.
------------------------------------------------------------------------

function onPlayerJoinGreet(player_id)
  local name = MP.GetPlayerName(player_id)
  if name then
    MP.SendChatMessage(-1, "Hello " .. name .. "!")
  end
end

MP.RegisterEvent("onPlayerJoin", "onPlayerJoinGreet")
