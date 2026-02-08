------------------------------------------------------------------------
-- BeamMP Server Plugin – Countdown & Timer Commands
--
-- Installation:
--   Drop this file into  Resources/Server/<your-folder>/  and restart
--   the BeamMP server.
--
-- Chat commands (prefix with "/"):
--   /help              List available commands.
--   /ss                Quick 5-second countdown.
--   /start [seconds]   Countdown (default 10 s, max 3600 s).
--   /timer <minutes>   Long timer  (required arg, max 180 min).
--   /time              Show remaining time on active timers.
--   /stop              Cancel all running timers.
--
-- Behaviour notes:
--   - Countdown announces every 5 s; every 1 s for the final 10 s.
--   - Timer announces remaining time (H:M:S) in 15 s buckets.
--   - Duplicate event-timer creation is guarded internally.
--   - All limits are configurable via the constants below.
------------------------------------------------------------------------

-- ── State ─────────────────────────────────────────────────────────────
local activeTimerEnd = nil             -- Unix timestamp when /timer expires
local activeCountdown = nil            -- Seconds left for the active countdown
local lastTimerAnnounceBucket = nil     -- Last announced 15 s bucket
local timersRunning = {}               -- Guard table: prevents duplicate event timers

-- ── Configuration ─────────────────────────────────────────────────────
local MAX_TIMER_MINUTES = 180           -- Upper bound for /timer
local MAX_COUNTDOWN_SECONDS = 3600      -- Upper bound for /start
local TIMER_ANNOUNCE_INTERVAL = 15      -- Seconds between timer announcements
local FINAL_COUNTDOWN_THRESHOLD = 10    -- Switch to per-second announcements

-- ── Utility ───────────────────────────────────────────────────────────
local function split(input)
  local t = {}
  for part in string.gmatch(input, "%S+") do t[#t+1] = part end
  return t
end

local function formatHMS(seconds)
  if seconds < 60 then
    return seconds .. "s"
  elseif seconds < 3600 then
    local m = math.floor(seconds / 60)
    local s = seconds % 60
    return string.format("%dm %02ds", m, s)
  else
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    return string.format("%dh %02dm %02ds", h, m, s)
  end
end

--- Create an event timer only if one with the same name isn't already running.
local function ensureEventTimer(name, intervalMs)
  if not timersRunning[name] then
    MP.CreateEventTimer(name, intervalMs)
    timersRunning[name] = true
  end
end

local function stopAll()
  activeTimerEnd = nil
  activeCountdown = nil
  lastTimerAnnounceBucket = nil
  -- Cancel any running event timers we know about
  if timersRunning["countdownEvent"] then MP.CancelEventTimer("countdownEvent") end
  if timersRunning["timerUpdateEvent"] then MP.CancelEventTimer("timerUpdateEvent") end
  timersRunning = {}
end

-- ── Event Handlers ────────────────────────────────────────────────────
function countdown_handler()
  if not activeCountdown then
    if timersRunning["countdownEvent"] then
      MP.CancelEventTimer("countdownEvent")
      timersRunning["countdownEvent"] = nil
    end
    return
  end
  if activeCountdown > 0 then
    if activeCountdown <= FINAL_COUNTDOWN_THRESHOLD or activeCountdown % 5 == 0 then
      MP.SendChatMessage(-1, "Countdown: " .. activeCountdown .. "s")
    end
    activeCountdown = activeCountdown - 1
  else
    MP.SendChatMessage(-1, "Countdown finished!")
    activeCountdown = nil
    if timersRunning["countdownEvent"] then
      MP.CancelEventTimer("countdownEvent")
      timersRunning["countdownEvent"] = nil
    end
  end
end

function timer_update_handler()
  if not activeTimerEnd then
    if timersRunning["timerUpdateEvent"] then
      MP.CancelEventTimer("timerUpdateEvent")
      timersRunning["timerUpdateEvent"] = nil
    end
    return
  end

  local remaining = activeTimerEnd - os.time()
  if remaining <= 0 then
    MP.SendChatMessage(-1, "Timer finished!")
    activeTimerEnd = nil
    lastTimerAnnounceBucket = nil
    if timersRunning["timerUpdateEvent"] then
      MP.CancelEventTimer("timerUpdateEvent")
      timersRunning["timerUpdateEvent"] = nil
    end
    return
  end

  -- Announce only when we cross into a new 15 s bucket
  local bucket = math.floor(remaining / TIMER_ANNOUNCE_INTERVAL)
  if bucket ~= lastTimerAnnounceBucket then
    lastTimerAnnounceBucket = bucket
    MP.SendChatMessage(
      -1,
      "Timer: " .. formatHMS(remaining) .. " remaining..."
    )
  end
end

MP.RegisterEvent("countdownEvent", "countdown_handler")
MP.RegisterEvent("timerUpdateEvent", "timer_update_handler")

-- ── Command Handlers ──────────────────────────────────────────────────
local commands = {}

commands.help = function(sender)
  MP.SendChatMessage(sender, "/ss (5s) | /start [sec] | /timer <min> | /time | /stop")
end

commands.start = function(_, args)
  if activeCountdown then
    MP.SendChatMessage(-1, "A countdown is already running.")
    return
  end
  local v = tonumber(args[1] or "10")
  if not v or v <= 0 then
    MP.SendChatMessage(-1, "Usage: /start [seconds]")
    return
  end
  if v > MAX_COUNTDOWN_SECONDS then
    MP.SendChatMessage(-1, "Max countdown is " .. MAX_COUNTDOWN_SECONDS .. " seconds.")
    return
  end
  activeCountdown = math.floor(v)
  MP.SendChatMessage(-1, "Countdown started: " .. activeCountdown .. "s.")
  ensureEventTimer("countdownEvent", 1000)
end

commands.ss = function()
  if activeCountdown then
    MP.SendChatMessage(-1, "A countdown is already running.")
    return
  end
  activeCountdown = 5
  MP.SendChatMessage(-1, "Starting 5 second countdown.")
  ensureEventTimer("countdownEvent", 1000)
end

commands.timer = function(_, args)
  local m = tonumber(args[1] or "")
  if not m or m <= 0 then
    MP.SendChatMessage(-1, "Usage: /timer <minutes>")
    return
  end
  if m > MAX_TIMER_MINUTES then
    MP.SendChatMessage(-1, "Max timer is " .. MAX_TIMER_MINUTES .. " minutes.")
    return
  end
  if activeTimerEnd then
    MP.SendChatMessage(-1, "A timer is already running.")
    return
  end
  activeTimerEnd = os.time() + (m * 60)
  lastTimerAnnounceBucket = nil
  MP.SendChatMessage(-1, "Timer started for " .. m .. " minute(s).")
  ensureEventTimer("timerUpdateEvent", 1000)
end

commands.time = function()
  local parts = {}
  if activeCountdown then
    parts[#parts+1] = "Countdown: " .. activeCountdown .. "s"
  end
  if activeTimerEnd then
    local remaining = math.max(0, activeTimerEnd - os.time())
    parts[#parts+1] = "Timer: " .. formatHMS(remaining)
  end
  if #parts == 0 then
    MP.SendChatMessage(-1, "No active timers.")
  else
    MP.SendChatMessage(-1, table.concat(parts, " | "))
  end
end

commands.stop = function()
  if not (activeCountdown or activeTimerEnd) then
    MP.SendChatMessage(-1, "No active timers.")
    return
  end
  stopAll()
  MP.SendChatMessage(-1, "All timers stopped.")
end

-- ── Chat Dispatcher ───────────────────────────────────────────────────
function chat_handler(sender_id, sender_name, message)
  if string.sub(message, 1, 1) ~= "/" then return end
  local parts = split(message)
  local cmd = string.lower(string.sub(parts[1], 2)) -- remove '/'
  local args = {}
  for i = 2, #parts do args[#args+1] = parts[i] end

  local handler = commands[cmd]
  if handler then
    handler(sender_id, args)
  else
    MP.SendChatMessage(sender_id, "Unknown command. Try /help")
  end
end

MP.RegisterEvent("onChatMessage", "chat_handler")