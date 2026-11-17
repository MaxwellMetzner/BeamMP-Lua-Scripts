BeamMP Server - Race Utilities
==============================

Overview
--------
This plugin provides race countdowns, timers, player greetings, a player
list, and a persistent win scoreboard. Commands are registered in one
place and dispatched by one onChatMessage handler.

Installation
------------
1. Open Resources/Server in your BeamMP server directory.
2. Create a plugin folder, for example Resources/Server/race-utilities.
3. Copy script.lua into that folder.
4. Start or restart the BeamMP server.

When upgrading from the previous multi-file version, replace script.lua
and remove greeter.lua and wins.lua. Their behavior is now included in
script.lua.

Commands
--------
  /help [command]    List commands or describe one command.
  /ss                Start a five-second countdown.
  /start [seconds]   Start a countdown; defaults to 10 seconds.
  /timer <minutes>   Start a long-running timer.
  /time              Show remaining countdown and timer time.
  /stop              Stop all countdowns and timers.
  /players           Privately list connected players and server IDs.
  /win <name>        Award a win using a unique name prefix.
  /removew <name>    Remove a win using a unique name prefix.
  /scoreboard        Broadcast the current standings.
  /clearwins         Reset the scoreboard.

Countdowns and timers
---------------------
Countdowns use an absolute end time, so delayed or skipped BeamMP timer
callbacks do not make the countdown drift. Countdown values and timer
minutes must be positive whole numbers.

The default limits are:
  Countdown: 3600 seconds
  Timer:     180 minutes

These and the announcement intervals can be changed in the CONFIG table
at the top of script.lua.

Scoreboard persistence
----------------------
The scoreboard is stored as versioned JSON:

  data/wins.json

Before replacing the primary file, the plugin writes and flushes a
temporary file, stages the previous file for rollback, and installs the
new file with a rename. It then refreshes a known-good backup at:

  data/wins.json.bak

If the primary file is missing or invalid, the backup is loaded. Invalid
records, read/write failures, command failures, and migration problems
are written to the BeamMP server log.

The old wins_data.lua format is migrated automatically without executing
the file. After a successful migration, it is moved to:

  data/wins_data.lua.migrated

If a scoreboard change cannot be saved, the in-memory change is rolled
back and the command sender is notified.

Name matching
-------------
Win commands match names case-insensitively. An exact match takes
priority; otherwise, a unique prefix can be used. Matching includes
connected players and names already present on the scoreboard.
