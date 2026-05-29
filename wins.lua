---@diagnostic disable: undefined-global

------------------------------------------------------------------------
-- BeamMP Server Plugin – Win Tracker
--
-- Tracks per-player win tallies via chat commands. Wins persist across
-- server restarts in a plain Lua data file.
--
-- Chat commands:
--   /win <name>      Award a win to a player (partial name match).
--   /removew <name>  Remove a win from a player (partial name match).
--   /scoreboard      Show the current win standings.
--   /clearwins       Reset the entire scoreboard.
--
-- Name matching:
--   You only need to type enough of a player's name to uniquely
--   identify them (case-insensitive). If several names match the
--   input, the command asks you to be more specific.
------------------------------------------------------------------------

-- ── Persistence ─────────────────────────────────────────────────────
local function resolvePluginDir()
  local source = debug.getinfo(1, "S").source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  local normalized = source:gsub("\\", "/")
  return normalized:match("^(.*)/[^/]+$") or "."
end

local WINS_FILE = resolvePluginDir() .. "/wins_data.lua"

--- Load the wins table from disk. Returns an empty table on failure.
local function loadWins()
  local fn = loadfile(WINS_FILE)
  if fn then
    local ok, data = pcall(fn)
    if ok and type(data) == "table" then return data end
  end
  return {}
end

--- Save the wins table to disk as a Lua chunk that returns a table.
local function saveWins(data)
  local f = io.open(WINS_FILE, "w")
  if not f then return end
  f:write("return {\n")
  for name, count in pairs(data) do
    -- Escape any special characters in player names
    local escaped = name:gsub("\\", "\\\\"):gsub('"', '\\"')
    f:write(string.format('  ["%s"] = %d,\n', escaped, count))
  end
  f:write("}\n")
  f:close()
end

-- ── State ───────────────────────────────────────────────────────────
local wins = loadWins()

-- ── Utility ─────────────────────────────────────────────────────────
local function split(input)
  local t = {}
  for part in string.gmatch(input, "%S+") do t[#t + 1] = part end
  return t
end

--- Build a set of known player names (connected + anyone in the wins db).
local function knownNames()
  local names = {}
  -- Connected players
  local players = MP.GetPlayers()
  if players then
    for id, name in pairs(players) do
      names[name] = true
    end
  end
  -- Historical winners (may be offline)
  for name, _ in pairs(wins) do
    names[name] = true
  end
  return names
end

--- Resolve a partial query to a single known player name.
--- Returns  (fullName, nil)  on unique match,
---          (nil, errorMsg)  otherwise.
local function resolvePlayer(query)
  if not query or query == "" then
    return nil, "No player name provided."
  end

  local lowerQ = query:lower()
  local matches = {}

  for name, _ in pairs(knownNames()) do
    if name:lower():sub(1, #lowerQ) == lowerQ then
      matches[#matches + 1] = name
    end
  end

  if #matches == 0 then
    return nil, 'No player found matching "' .. query .. '".'
  elseif #matches == 1 then
    return matches[1], nil
  else
    -- Sort for a deterministic message
    table.sort(matches)
    return nil, "Multiple matches: " .. table.concat(matches, ", ")
        .. ". Be more specific."
  end
end

--- Announce the scoreboard to all players.
local function announceScoreboard()
  -- Collect entries and sort descending by wins
  local entries = {}
  for name, count in pairs(wins) do
    entries[#entries + 1] = { name = name, count = count }
  end

  if #entries == 0 then
    MP.SendChatMessage(-1, "Scoreboard is empty.")
    return
  end

  table.sort(entries, function(a, b)
    if a.count == b.count then return a.name < b.name end
    return a.count > b.count
  end)

  MP.SendChatMessage(-1, "── Scoreboard ──")
  for i, e in ipairs(entries) do
    local suffix = e.count == 1 and " win" or " wins"
    MP.SendChatMessage(-1, "#" .. i .. "  " .. e.name .. " — " .. e.count .. suffix)
  end
end

-- ── Command Handlers ────────────────────────────────────────────────
local winsCommands = {}

winsCommands.win = function(sender, args)
  local query = table.concat(args, " ")
  local name, err = resolvePlayer(query)
  if not name then
    MP.SendChatMessage(sender, err)
    return
  end
  wins[name] = (wins[name] or 0) + 1
  saveWins(wins)
  MP.SendChatMessage(-1, name .. " earned a win! (" .. wins[name] .. " total)")
  announceScoreboard()
end

winsCommands.removew = function(sender, args)
  local query = table.concat(args, " ")
  local name, err = resolvePlayer(query)
  if not name then
    MP.SendChatMessage(sender, err)
    return
  end
  if not wins[name] or wins[name] <= 0 then
    MP.SendChatMessage(sender, name .. " has no wins to remove.")
    return
  end
  wins[name] = wins[name] - 1
  if wins[name] <= 0 then wins[name] = nil end
  saveWins(wins)
  local total = wins[name] or 0
  MP.SendChatMessage(-1, "Removed a win from " .. name .. ". (" .. total .. " total)")
  announceScoreboard()
end

winsCommands.scoreboard = function()
  announceScoreboard()
end

winsCommands.clearwins = function()
  wins = {}
  saveWins(wins)
  MP.SendChatMessage(-1, "Scoreboard has been cleared.")
end

-- ── Chat Dispatcher ─────────────────────────────────────────────────
function wins_chat_handler(sender_id, sender_name, message)
  if message:sub(1, 1) ~= "/" then return 0 end

  local parts = split(message)
  local cmd = parts[1]:sub(2):lower()   -- strip leading "/"
  local args = {}
  for i = 2, #parts do args[#args + 1] = parts[i] end

  local handler = winsCommands[cmd]
  if handler then
    handler(sender_id, args)
    return 1
  end
  -- Unknown commands are intentionally ignored here so the main
  -- script's dispatcher can handle them instead.
  return 0
end

MP.RegisterEvent("onChatMessage", "wins_chat_handler")
