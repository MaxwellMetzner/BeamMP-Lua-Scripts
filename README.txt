BeamMP Server – Lua Plugin Collection
=======================================

Overview
--------
A set of Lua server-side plugins for BeamMP that add useful chat commands
for running races and events. All scripts are loaded automatically by the
BeamMP server from the same plugin folder.

Scripts included:
  script.lua   – Countdown & timer commands.
  greeter.lua  – Auto-greets players when they join.
  wins.lua     – Per-player win tracker with scoreboard.

Installation
------------
1. In your BeamMP server directory, navigate to:
       Resources/Server/
2. Create a new folder (e.g. "maxscript") inside that path.
3. Drop all .lua files into the new folder.
4. Restart (or start) the BeamMP server – every .lua file in the
   folder is loaded automatically.

=========================================================================
script.lua – Countdown & Timer
=========================================================================

Commands
--------
  /help              List every available command with a short summary.
  /ss                Quick-start a 5-second countdown.
  /start [seconds]   Start a countdown. Defaults to 10 s if no value is
                     given. Maximum allowed value is 3600 s (1 hour).
  /timer <minutes>   Start a long-running timer. The <minutes> argument is
                     required. Maximum allowed value is 180 min (3 hours).
  /time              Display the remaining time on any active countdown
                     and/or timer.
  /stop              Cancel all running countdowns and timers immediately.
  /players           Show the current player count and each connected
                     player's BeamMP ID and name to the requester.

Behaviour
---------
* Countdown (/ss, /start)
  - Announces every 5 seconds while running.
  - Switches to every-second announcements for the final 10 seconds.
  - Prevents starting a second countdown while one is already active.

* Timer (/timer)
  - Announces remaining time in human-readable H:M:S format.
  - Announcements are bucketed every 15 seconds to avoid chat spam.
  - Prevents starting a second timer while one is already active.

* General
  - Duplicate internal event-timers are guarded against automatically.
  - All limits (max seconds, max minutes, announce interval, final
    threshold) are configurable constants at the top of the script.
  - /players replies only to the caller so large lobbies do not get
    extra chat spam.
  - An unknown "/" command returns a helpful hint to the sender only.

=========================================================================
greeter.lua – Auto-Greeter
=========================================================================

Behaviour
---------
  When a player joins the server, a message is broadcast to all players:

      Hello <playername>!

  No commands – fully automatic.

=========================================================================
wins.lua – Win Tracker & Scoreboard
=========================================================================

Commands
--------
  /win <name>        Award a win to a player.
  /removew <name>    Remove a win from a player.
  /scoreboard        Display the current win standings.
  /clearwins         Reset the entire scoreboard to zero.

Name Matching
-------------
  You don't need to type a player's full name. Type just enough
  characters to uniquely match them (case-insensitive).

  Examples (if "MaxwellSilver" is the only name starting with "max"):
      /win max          →  awards a win to MaxwellSilver
      /win Maxwell      →  same result
      /win MaxwellSilver → also works

  If the partial name matches more than one player, the command will
  list the matches and ask you to be more specific.

  Names are matched against both currently connected players AND anyone
  who already has wins on the scoreboard (so you can award offline
  players too).

Behaviour
---------
  - After every /win or /removew the full scoreboard is announced.
  - Wins are saved to  wins_data.lua  and persist across server
    restarts.
  - /clearwins wipes the saved file as well.