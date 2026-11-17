---@diagnostic disable: undefined-global

------------------------------------------------------------------------
-- BeamMP Server Plugin - Race Utilities
--
-- Provides countdowns, timers, player listing, greetings, and a
-- persistent win scoreboard through one command registry and one chat
-- event handler.
------------------------------------------------------------------------

-- Configuration --------------------------------------------------------

local CONFIG = {
  maxTimerMinutes = 180,
  maxCountdownSeconds = 3600,
  timerAnnounceInterval = 15,
  finalCountdownThreshold = 10,
  helpChunkLength = 220,
}

local EVENT_COUNTDOWN_TICK = "BeamMPRace.CountdownTick"
local EVENT_TIMER_TICK = "BeamMPRace.TimerTick"

-- Logging --------------------------------------------------------------

local function log(level, ...)
  local loggerName = "Log" .. level
  if type(Util) == "table" and type(Util[loggerName]) == "function" then
    Util[loggerName](...)
  else
    print("[BeamMPRace][" .. level .. "]", ...)
  end
end

-- Files and persistence ------------------------------------------------

local function resolvePluginDir()
  local source = debug.getinfo(1, "S").source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  local normalized = source:gsub("\\", "/")
  return normalized:match("^(.*)/[^/]+$") or "."
end

local PLUGIN_DIR = resolvePluginDir()
local DATA_DIR = PLUGIN_DIR .. "/data"
local WINS_FILE = DATA_DIR .. "/wins.json"
local WINS_TEMP_FILE = DATA_DIR .. "/wins.json.tmp"
local WINS_BACKUP_FILE = DATA_DIR .. "/wins.json.bak"
local WINS_OLD_FILE = DATA_DIR .. "/wins.json.old"
local LEGACY_WINS_FILE = PLUGIN_DIR .. "/wins_data.lua"
local LEGACY_WINS_ARCHIVE = DATA_DIR .. "/wins_data.lua.migrated"

local function pathIsFile(path)
  if type(FS) == "table" and type(FS.IsFile) == "function" then
    local ok, result = pcall(FS.IsFile, path)
    return ok and result == true
  end

  local file = io.open(path, "rb")
  if file then
    file:close()
    return true
  end
  return false
end

local function ensureDataDir()
  if type(FS) ~= "table" or type(FS.CreateDirectory) ~= "function" then
    return false, "BeamMP FS.CreateDirectory is unavailable"
  end

  if type(FS.IsDirectory) == "function" then
    local ok, exists = pcall(FS.IsDirectory, DATA_DIR)
    if ok and exists then return true end
  end

  local ok, created, err = pcall(FS.CreateDirectory, DATA_DIR)
  if not ok then return false, tostring(created) end
  if not created then return false, err or "unknown directory creation error" end
  return true
end

local function readFile(path)
  local file, openErr = io.open(path, "rb")
  if not file then return nil, openErr or "could not open file" end

  local contents, readErr = file:read("*a")
  local closeOk, closeErr = file:close()
  if contents == nil then return nil, readErr or "could not read file" end
  if closeOk == nil then return nil, closeErr or "could not close file" end
  return contents
end

local function writeFile(path, contents)
  local file, openErr = io.open(path, "wb")
  if not file then return false, openErr or "could not open file" end

  local wrote, writeErr = file:write(contents)
  if not wrote then
    file:close()
    return false, writeErr or "could not write file"
  end

  local flushed, flushErr = file:flush()
  if not flushed then
    file:close()
    return false, flushErr or "could not flush file"
  end

  local closed, closeErr = file:close()
  if not closed then return false, closeErr or "could not close file" end
  return true
end

local function removeFile(path)
  if not pathIsFile(path) then return true end
  if type(FS) ~= "table" or type(FS.Remove) ~= "function" then
    return false, "BeamMP FS.Remove is unavailable"
  end

  local ok, removed, err = pcall(FS.Remove, path)
  if not ok then return false, tostring(removed) end
  if not removed then return false, err or "unknown remove error" end
  return true
end

local function renameFile(oldPath, newPath)
  if type(FS) ~= "table" or type(FS.Rename) ~= "function" then
    return false, "BeamMP FS.Rename is unavailable"
  end

  local ok, renamed, err = pcall(FS.Rename, oldPath, newPath)
  if not ok then return false, tostring(renamed) end
  if not renamed then return false, err or "unknown rename error" end
  return true
end

local function copyFile(oldPath, newPath)
  if type(FS) ~= "table" or type(FS.Copy) ~= "function" then
    return false, "BeamMP FS.Copy is unavailable"
  end

  local ok, copied, err = pcall(FS.Copy, oldPath, newPath)
  if not ok then return false, tostring(copied) end
  if not copied then return false, err or "unknown copy error" end
  return true
end

local function decodeWinsDocument(contents, sourceName)
  if type(Util) ~= "table" or type(Util.JsonDecode) ~= "function" then
    return nil, "BeamMP Util.JsonDecode is unavailable"
  end

  local ok, document = pcall(Util.JsonDecode, contents)
  if not ok then return nil, tostring(document) end
  if type(document) ~= "table" then
    return nil, sourceName .. " does not contain a JSON object"
  end
  if document.version ~= 1 then
    return nil, sourceName .. " has an unsupported data version"
  end
  if type(document.wins) ~= "table" then
    return nil, sourceName .. " does not contain a wins object"
  end

  local result = {}
  local rejected = 0
  for name, count in pairs(document.wins) do
    if type(name) == "string"
        and name ~= ""
        and type(count) == "number"
        and count > 0
        and count == math.floor(count) then
      result[name] = count
    else
      rejected = rejected + 1
    end
  end

  if rejected > 0 then
    log("Warn", "Ignored " .. rejected .. " invalid scoreboard entrie(s) in " .. sourceName)
  end
  return result
end

local function loadJsonWins(path)
  local contents, readErr = readFile(path)
  if not contents then return nil, readErr end
  return decodeWinsDocument(contents, path)
end

local function saveWins(data)
  local dirOk, dirErr = ensureDataDir()
  if not dirOk then return false, dirErr end
  if type(Util) ~= "table" or type(Util.JsonEncode) ~= "function" then
    return false, "BeamMP Util.JsonEncode is unavailable"
  end

  local encodedOk, encoded = pcall(Util.JsonEncode, {
    version = 1,
    wins = data,
  })
  if not encodedOk or type(encoded) ~= "string" then
    return false, "could not encode scoreboard: " .. tostring(encoded)
  end

  local removedTemp, tempRemoveErr = removeFile(WINS_TEMP_FILE)
  if not removedTemp then return false, tempRemoveErr end
  local removedOld, oldRemoveErr = removeFile(WINS_OLD_FILE)
  if not removedOld then return false, oldRemoveErr end

  local wrote, writeErr = writeFile(WINS_TEMP_FILE, encoded .. "\n")
  if not wrote then return false, writeErr end

  local hadCurrent = pathIsFile(WINS_FILE)
  if hadCurrent then
    local movedOld, moveOldErr = renameFile(WINS_FILE, WINS_OLD_FILE)
    if not movedOld then
      removeFile(WINS_TEMP_FILE)
      return false, "could not stage the previous scoreboard: " .. tostring(moveOldErr)
    end
  end

  local installed, installErr = renameFile(WINS_TEMP_FILE, WINS_FILE)
  if not installed then
    if hadCurrent then
      local restored, restoreErr = renameFile(WINS_OLD_FILE, WINS_FILE)
      if not restored then
        log("Error", "Scoreboard restore failed: " .. tostring(restoreErr))
      end
    end
    removeFile(WINS_TEMP_FILE)
    return false, "could not install scoreboard: " .. tostring(installErr)
  end

  local removedBackup, backupRemoveErr = removeFile(WINS_BACKUP_FILE)
  if not removedBackup then
    log("Warn", "Could not replace scoreboard backup: " .. tostring(backupRemoveErr))
  else
    local copiedBackup, backupErr = copyFile(WINS_FILE, WINS_BACKUP_FILE)
    if not copiedBackup then
      log("Warn", "Could not create scoreboard backup: " .. tostring(backupErr))
    end
  end

  if hadCurrent then
    local cleanedOld, cleanOldErr = removeFile(WINS_OLD_FILE)
    if not cleanedOld then
      log("Warn", "Could not remove staged scoreboard: " .. tostring(cleanOldErr))
    end
  end

  return true
end

local function decodeLegacyName(encoded)
  local result = {}
  local index = 1
  while index <= #encoded do
    local char = encoded:sub(index, index)
    if char == "\\" then
      local escaped = encoded:sub(index + 1, index + 1)
      if escaped ~= "\\" and escaped ~= '"' then
        return nil, "unsupported escape sequence"
      end
      result[#result + 1] = escaped
      index = index + 2
    else
      result[#result + 1] = char
      index = index + 1
    end
  end
  return table.concat(result)
end

local function parseLegacyWins(contents)
  local result = {}
  local sawStart = false
  local sawEnd = false

  contents = contents:gsub("\r", "")
  for line in (contents .. "\n"):gmatch("(.-)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      if not sawStart and trimmed == "return {" then
        sawStart = true
      elseif sawStart and not sawEnd and trimmed == "}" then
        sawEnd = true
      elseif sawStart and not sawEnd then
        local encodedName, countText = trimmed:match('^%["(.*)"%]%s*=%s*(%d+),?$')
        if not encodedName then
          return nil, "legacy data contains an unexpected line"
        end
        local name, nameErr = decodeLegacyName(encodedName)
        local count = tonumber(countText)
        if not name or name == "" or not count or count <= 0 then
          return nil, nameErr or "legacy data contains an invalid entry"
        end
        result[name] = count
      else
        return nil, "legacy data contains content after the table"
      end
    end
  end

  if not sawStart or not sawEnd then
    return nil, "legacy data is incomplete"
  end
  return result
end

local function migrateLegacyWins()
  if not pathIsFile(LEGACY_WINS_FILE) then return nil end

  local contents, readErr = readFile(LEGACY_WINS_FILE)
  if not contents then
    log("Error", "Could not read legacy scoreboard: " .. tostring(readErr))
    return nil
  end

  local migrated, parseErr = parseLegacyWins(contents)
  if not migrated then
    log("Error", "Could not safely parse legacy scoreboard: " .. tostring(parseErr))
    return nil
  end

  local saved, saveErr = saveWins(migrated)
  if not saved then
    log("Error", "Could not save migrated scoreboard: " .. tostring(saveErr))
    return nil
  end

  if pathIsFile(LEGACY_WINS_ARCHIVE) then
    log("Warn", "Legacy scoreboard migrated, but an archive already exists; leaving the old file in place")
  else
    local archived, archiveErr = renameFile(LEGACY_WINS_FILE, LEGACY_WINS_ARCHIVE)
    if not archived then
      log("Warn", "Legacy scoreboard migrated, but could not archive it: " .. tostring(archiveErr))
    end
  end

  log("Info", "Migrated legacy scoreboard to " .. WINS_FILE)
  return migrated
end

local function loadWins()
  if pathIsFile(WINS_FILE) then
    local loaded, loadErr = loadJsonWins(WINS_FILE)
    if loaded then return loaded end
    log("Error", "Could not load scoreboard: " .. tostring(loadErr))
  end

  if pathIsFile(WINS_BACKUP_FILE) then
    local recovered, recoverErr = loadJsonWins(WINS_BACKUP_FILE)
    if recovered then
      log("Warn", "Loaded scoreboard from backup because the primary file was unavailable or invalid")
      return recovered
    end
    log("Error", "Could not load scoreboard backup: " .. tostring(recoverErr))
  end

  local migrated = migrateLegacyWins()
  if migrated then return migrated end

  log("Info", "Starting with an empty scoreboard")
  return {}
end

-- Shared state and utility functions -----------------------------------

local state = {
  countdownEnd = nil,
  timerEnd = nil,
  lastCountdownAnnouncement = nil,
  lastTimerAnnounceBucket = nil,
  eventTimers = {},
  wins = loadWins(),
}

local function splitWords(input)
  local result = {}
  for part in input:gmatch("%S+") do
    result[#result + 1] = part
  end
  return result
end

local function formatHMS(seconds)
  seconds = math.max(0, math.floor(seconds))
  if seconds < 60 then
    return seconds .. "s"
  elseif seconds < 3600 then
    local minutes = math.floor(seconds / 60)
    return string.format("%dm %02ds", minutes, seconds % 60)
  end

  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  return string.format("%dh %02dm %02ds", hours, minutes, seconds % 60)
end

local function parsePositiveInteger(rawValue, defaultValue, maximum, label)
  if rawValue == nil then rawValue = defaultValue end
  local value = tonumber(rawValue)
  if not value or value <= 0 or value ~= math.floor(value) then
    return nil, label .. " must be a positive whole number."
  end
  if value > maximum then
    return nil, label .. " cannot exceed " .. maximum .. "."
  end
  return value
end

local function getSortedPlayers()
  local entries = {}
  local players = MP.GetPlayers() or {}
  for playerId, playerName in pairs(players) do
    if type(playerName) == "string" and playerName ~= "" then
      entries[#entries + 1] = {
        id = tostring(playerId),
        name = playerName,
      }
    end
  end

  table.sort(entries, function(a, b)
    local aNumber = tonumber(a.id)
    local bNumber = tonumber(b.id)
    if aNumber and bNumber and aNumber ~= bNumber then
      return aNumber < bNumber
    end
    return a.id < b.id
  end)
  return entries
end

local function ensureEventTimer(name, intervalMs)
  if state.eventTimers[name] then return end
  MP.CreateEventTimer(name, intervalMs)
  state.eventTimers[name] = true
end

local function cancelEventTimer(name)
  if not state.eventTimers[name] then return end
  MP.CancelEventTimer(name)
  state.eventTimers[name] = nil
end

local function stopAllTimers()
  state.countdownEnd = nil
  state.timerEnd = nil
  state.lastCountdownAnnouncement = nil
  state.lastTimerAnnounceBucket = nil
  cancelEventTimer(EVENT_COUNTDOWN_TICK)
  cancelEventTimer(EVENT_TIMER_TICK)
end

-- Timer event handlers -------------------------------------------------

function BeamMPRace_countdownTick()
  if not state.countdownEnd then
    cancelEventTimer(EVENT_COUNTDOWN_TICK)
    return
  end

  local remaining = state.countdownEnd - os.time()
  if remaining <= 0 then
    MP.SendChatMessage(-1, "Countdown finished!")
    state.countdownEnd = nil
    state.lastCountdownAnnouncement = nil
    cancelEventTimer(EVENT_COUNTDOWN_TICK)
    return
  end

  if remaining ~= state.lastCountdownAnnouncement
      and (remaining <= CONFIG.finalCountdownThreshold or remaining % 5 == 0) then
    state.lastCountdownAnnouncement = remaining
    MP.SendChatMessage(-1, "Countdown: " .. remaining .. "s")
  end
end

function BeamMPRace_timerTick()
  if not state.timerEnd then
    cancelEventTimer(EVENT_TIMER_TICK)
    return
  end

  local remaining = state.timerEnd - os.time()
  if remaining <= 0 then
    MP.SendChatMessage(-1, "Timer finished!")
    state.timerEnd = nil
    state.lastTimerAnnounceBucket = nil
    cancelEventTimer(EVENT_TIMER_TICK)
    return
  end

  local bucket = math.floor(remaining / CONFIG.timerAnnounceInterval)
  if bucket ~= state.lastTimerAnnounceBucket then
    state.lastTimerAnnounceBucket = bucket
    MP.SendChatMessage(-1, "Timer: " .. formatHMS(remaining) .. " remaining...")
  end
end

-- Scoreboard helpers ---------------------------------------------------

local function knownNames()
  local names = {}
  local players = MP.GetPlayers() or {}
  for _, name in pairs(players) do
    if type(name) == "string" and name ~= "" then names[name] = true end
  end
  for name in pairs(state.wins) do names[name] = true end
  return names
end

local function resolvePlayer(query)
  if not query or query == "" then return nil, "No player name provided." end

  local lowerQuery = query:lower()
  local exactMatches = {}
  local prefixMatches = {}

  for name in pairs(knownNames()) do
    local lowerName = name:lower()
    if lowerName == lowerQuery then
      exactMatches[#exactMatches + 1] = name
    elseif lowerName:sub(1, #lowerQuery) == lowerQuery then
      prefixMatches[#prefixMatches + 1] = name
    end
  end

  local matches = #exactMatches > 0 and exactMatches or prefixMatches
  table.sort(matches, function(a, b) return a:lower() < b:lower() end)

  if #matches == 0 then
    return nil, 'No player found matching "' .. query .. '".'
  elseif #matches == 1 then
    return matches[1]
  end
  return nil, "Multiple matches: " .. table.concat(matches, ", ") .. ". Be more specific."
end

local function announceScoreboard()
  local entries = {}
  for name, count in pairs(state.wins) do
    entries[#entries + 1] = { name = name, count = count }
  end

  if #entries == 0 then
    MP.SendChatMessage(-1, "Scoreboard is empty.")
    return
  end

  table.sort(entries, function(a, b)
    if a.count == b.count then return a.name:lower() < b.name:lower() end
    return a.count > b.count
  end)

  MP.SendChatMessage(-1, "-- Scoreboard --")
  for index, entry in ipairs(entries) do
    local suffix = entry.count == 1 and " win" or " wins"
    MP.SendChatMessage(-1, "#" .. index .. "  " .. entry.name .. " - " .. entry.count .. suffix)
  end
end

local function persistOrRollback(sender, rollback)
  local saved, saveErr = saveWins(state.wins)
  if saved then return true end

  rollback()
  log("Error", "Could not save scoreboard: " .. tostring(saveErr))
  MP.SendChatMessage(sender, "The scoreboard could not be saved; no changes were applied.")
  return false
end

-- Command registry -----------------------------------------------------

local commands = {}
local commandOrder = {}

local function registerCommand(name, definition)
  assert(type(name) == "string" and name ~= "", "command name is required")
  assert(type(definition) == "table", "command definition is required")
  assert(type(definition.handler) == "function", "command handler is required")
  assert(not commands[name], "duplicate command: " .. name)

  definition.name = name
  definition.usage = definition.usage or ("/" .. name)
  definition.description = definition.description or ""
  definition.minArgs = definition.minArgs or 0
  commands[name] = definition
  commandOrder[#commandOrder + 1] = name
end

local function sendHelp(sender, requestedCommand)
  if requestedCommand then
    requestedCommand = requestedCommand:gsub("^/", ""):lower()
    local command = commands[requestedCommand]
    if not command then
      MP.SendChatMessage(sender, "Unknown command. Try /help")
      return
    end
    MP.SendChatMessage(sender, command.usage .. " - " .. command.description)
    return
  end

  local chunks = {}
  local current = "Commands: "
  for _, name in ipairs(commandOrder) do
    local entry = commands[name].usage
    local separator = current == "Commands: " and "" or " | "
    if #current + #separator + #entry > CONFIG.helpChunkLength then
      chunks[#chunks + 1] = current
      current = entry
    else
      current = current .. separator .. entry
    end
  end
  if current ~= "" then chunks[#chunks + 1] = current end

  for _, chunk in ipairs(chunks) do MP.SendChatMessage(sender, chunk) end
  MP.SendChatMessage(sender, "Use /help <command> for details.")
end

registerCommand("help", {
  usage = "/help [command]",
  description = "List commands or show details for one command.",
  maxArgs = 1,
  handler = function(sender, args) sendHelp(sender, args[1]) end,
})

registerCommand("ss", {
  usage = "/ss",
  description = "Start a five-second countdown.",
  maxArgs = 0,
  handler = function(sender)
    if state.countdownEnd then
      MP.SendChatMessage(sender, "A countdown is already running.")
      return
    end
    state.countdownEnd = os.time() + 5
    state.lastCountdownAnnouncement = nil
    MP.SendChatMessage(-1, "Starting 5 second countdown.")
    ensureEventTimer(EVENT_COUNTDOWN_TICK, 1000)
  end,
})

registerCommand("start", {
  usage = "/start [seconds]",
  description = "Start a countdown; defaults to 10 seconds.",
  maxArgs = 1,
  handler = function(sender, args)
    if state.countdownEnd then
      MP.SendChatMessage(sender, "A countdown is already running.")
      return
    end
    local seconds, parseErr = parsePositiveInteger(
      args[1], 10, CONFIG.maxCountdownSeconds, "Countdown seconds"
    )
    if not seconds then
      MP.SendChatMessage(sender, parseErr)
      return
    end

    state.countdownEnd = os.time() + seconds
    state.lastCountdownAnnouncement = nil
    MP.SendChatMessage(-1, "Countdown started: " .. seconds .. "s.")
    ensureEventTimer(EVENT_COUNTDOWN_TICK, 1000)
  end,
})

registerCommand("timer", {
  usage = "/timer <minutes>",
  description = "Start a long-running timer.",
  minArgs = 1,
  maxArgs = 1,
  handler = function(sender, args)
    if state.timerEnd then
      MP.SendChatMessage(sender, "A timer is already running.")
      return
    end
    local minutes, parseErr = parsePositiveInteger(
      args[1], nil, CONFIG.maxTimerMinutes, "Timer minutes"
    )
    if not minutes then
      MP.SendChatMessage(sender, parseErr)
      return
    end

    state.timerEnd = os.time() + (minutes * 60)
    state.lastTimerAnnounceBucket = nil
    MP.SendChatMessage(-1, "Timer started for " .. minutes .. " minute(s).")
    ensureEventTimer(EVENT_TIMER_TICK, 1000)
  end,
})

registerCommand("time", {
  usage = "/time",
  description = "Show remaining countdown and timer time.",
  maxArgs = 0,
  handler = function(sender)
    local parts = {}
    if state.countdownEnd then
      parts[#parts + 1] = "Countdown: " .. formatHMS(state.countdownEnd - os.time())
    end
    if state.timerEnd then
      parts[#parts + 1] = "Timer: " .. formatHMS(state.timerEnd - os.time())
    end
    MP.SendChatMessage(sender, #parts == 0 and "No active timers." or table.concat(parts, " | "))
  end,
})

registerCommand("stop", {
  usage = "/stop",
  description = "Stop all active countdowns and timers.",
  maxArgs = 0,
  handler = function(sender)
    if not state.countdownEnd and not state.timerEnd then
      MP.SendChatMessage(sender, "No active timers.")
      return
    end
    stopAllTimers()
    MP.SendChatMessage(-1, "All timers stopped.")
  end,
})

registerCommand("players", {
  usage = "/players",
  description = "List connected players and their server IDs.",
  maxArgs = 0,
  handler = function(sender)
    local players = getSortedPlayers()
    local suffix = #players == 1 and " player" or " players"
    MP.SendChatMessage(sender, "There are currently " .. #players .. suffix .. " on the server.")
    for _, player in ipairs(players) do
      MP.SendChatMessage(sender, "ID: " .. player.id .. " Name: " .. player.name)
    end
  end,
})

registerCommand("win", {
  usage = "/win <name>",
  description = "Award a win using a unique name prefix.",
  minArgs = 1,
  handler = function(sender, args)
    local name, resolveErr = resolvePlayer(table.concat(args, " "))
    if not name then
      MP.SendChatMessage(sender, resolveErr)
      return
    end

    local previous = state.wins[name]
    state.wins[name] = (previous or 0) + 1
    if not persistOrRollback(sender, function() state.wins[name] = previous end) then return end

    MP.SendChatMessage(-1, name .. " earned a win! (" .. state.wins[name] .. " total)")
    announceScoreboard()
  end,
})

registerCommand("removew", {
  usage = "/removew <name>",
  description = "Remove a win using a unique name prefix.",
  minArgs = 1,
  handler = function(sender, args)
    local name, resolveErr = resolvePlayer(table.concat(args, " "))
    if not name then
      MP.SendChatMessage(sender, resolveErr)
      return
    end
    if not state.wins[name] or state.wins[name] <= 0 then
      MP.SendChatMessage(sender, name .. " has no wins to remove.")
      return
    end

    local previous = state.wins[name]
    local updated = previous - 1
    state.wins[name] = updated > 0 and updated or nil
    if not persistOrRollback(sender, function() state.wins[name] = previous end) then return end

    MP.SendChatMessage(-1, "Removed a win from " .. name .. ". (" .. updated .. " total)")
    announceScoreboard()
  end,
})

registerCommand("scoreboard", {
  usage = "/scoreboard",
  description = "Display the current win standings.",
  maxArgs = 0,
  handler = function() announceScoreboard() end,
})

registerCommand("clearwins", {
  usage = "/clearwins",
  description = "Reset the entire scoreboard.",
  maxArgs = 0,
  handler = function(sender)
    local previous = state.wins
    state.wins = {}
    if not persistOrRollback(sender, function() state.wins = previous end) then return end
    MP.SendChatMessage(-1, "Scoreboard has been cleared.")
  end,
})

-- BeamMP event handlers ------------------------------------------------

function BeamMPRace_chatHandler(senderId, senderName, message)
  if type(message) ~= "string" or message:sub(1, 1) ~= "/" then return 0 end

  local parts = splitWords(message)
  local commandName = parts[1] and parts[1]:sub(2):lower() or ""
  local command = commands[commandName]
  if not command then
    MP.SendChatMessage(senderId, "Unknown command. Try /help")
    return 1
  end

  local args = {}
  for index = 2, #parts do args[#args + 1] = parts[index] end
  if #args < command.minArgs or (command.maxArgs and #args > command.maxArgs) then
    MP.SendChatMessage(senderId, "Usage: " .. command.usage)
    return 1
  end

  local ok, handlerErr = pcall(command.handler, senderId, args, senderName)
  if not ok then
    log("Error", "Command /" .. commandName .. " failed: " .. tostring(handlerErr))
    MP.SendChatMessage(senderId, "That command failed. Check the server log for details.")
  end
  return 1
end

function BeamMPRace_playerJoinHandler(playerId)
  local name = MP.GetPlayerName(playerId)
  if type(name) == "string" and name ~= "" then
    MP.SendChatMessage(-1, "Hello " .. name .. "!")
  else
    log("Warn", "Could not greet player ID " .. tostring(playerId) .. ": name was unavailable")
  end
end

MP.RegisterEvent(EVENT_COUNTDOWN_TICK, "BeamMPRace_countdownTick")
MP.RegisterEvent(EVENT_TIMER_TICK, "BeamMPRace_timerTick")
MP.RegisterEvent("onChatMessage", "BeamMPRace_chatHandler")
MP.RegisterEvent("onPlayerJoin", "BeamMPRace_playerJoinHandler")

log("Info", "Loaded race utilities with " .. #commandOrder .. " commands")
