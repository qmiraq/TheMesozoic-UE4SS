THE MESOZOIC AI SPAWN MANAGER - alpha v0.2.4

This is the safety-probe foundation for the website AI Spawn Manager.

It can:
- capture an allowlisted administrator's linked live dinosaur world position;
- inspect reflected Maiasaura and AI-controller functions without calling them;
- trace a website-selected Gateway XY down to a blocking terrain surface;
- spawn a manually selected, approved land-AI test group when an administrator
  explicitly presses the test button.

It does not:
- run an automatic spawn loop;
- cache or delete spawned AI;
- mark spawned AI always-relevant;
- invoke unknown call/vocal functions;
- process a historical spawn command after restart.

Manual tests are enabled for Maiasaura, Diabloceratops, Beipiaosaurus, and
Hypsilophodon. Deinosuchus, Elite Catfish, and Elite Coelacanth are
configuration-only until water-presence and depth validation is confirmed.
Existing native fish spawners are never modified.

Files:
Saved\commands.tsv       Website-to-game probe commands
Saved\command.cursor     Persistent command cursor
Saved\events.ndjson      Probe results shown on the admin page
Saved\spawn-config.json  Disabled-by-default zone configuration
Saved\gateway-calibration.json  Shared AI-map and heatmap transform

After installation, restart the game server once. Then sign into the website
and open https://mesozoic.gg/Admin/AI

Recommended test order:
1. Inspect hooks.
2. Click a known dry-land point and trace it.
3. Verify the returned Z looks plausible.
4. With the server empty or quiet, spawn one Maiasaura.
5. Observe whether it appears, walks, pathfinds, calls naturally, can be killed,
   creates a normal corpse, and is visible to a second nearby player.

The live probe cannot be deleted from the website. Kill it normally or let the
next scheduled server restart clear it.

V0.1.1 grows the pawn away from terrain, reads the grown capsule height, then
places it back at the requested XY above the traced surface. The event panel
shows requested and actual coordinates so displacement is immediately visible.

V0.1.2 adds live-position calibration for the 1600x1600 V8 Gateway map. Use at
least three widely separated points; five points across the island are
recommended. Applying the fit updates AI placement and the Discord heatmap
through one shared calibration file.

V0.1.3 corrects installer validation; the game-side calibration probe remains
the unchanged, validated V0.1.2 implementation.

V0.1.4 adds website-only precision zooming and panning. The game-side probe is
still the unchanged, validated V0.1.2 implementation.

V0.1.5 corrects zoomed marker alignment and keeps every displayed point a
fixed-size circle. The game-side probe remains unchanged.

V0.1.6 adds the live world-coordinate fields to the probe event serializer.
Restart the game server once after installation so the corrected Lua probe is
loaded before capturing calibration points.

V0.2.0 hides calibration from the normal website panel while preserving the
applied transform. It adds all requested species profiles, three visible zone
radii, per-member growth distributions, aquatic depth bands, and explicit
manual land AI test spawning. Automatic spawning remains disabled.

V0.2.1 replaces the single-AI test with full-group spawning. Each member uses
its configured growth entry and receives a random point within the configured
spawn radius. Multiple groups can be tested without restarting. There is no
global configured-AI count or lifetime manual-spawn limit; commands are still
processed sequentially to avoid creating several groups in the same game tick.

V0.2.2 moves the members of every group into a game-side queue. Exactly one
member is created per poll tick, preventing Unreal from silently accepting only
the first pawn/controller pair when a complete group is requested at once.

V0.2.3 turns that queue into a paced, verified group job. Members are attempted
four seconds apart, transient failures are retried up to three times, and the
group is complete only after every member has a verified pawn/controller
possession or has exhausted its retries.

V0.2.4 reduces verified group spacing to one second and adds the first
lifecycle-controller test. Only AI created by a manual group test are tracked.
The controller re-enumerates current world actors rather than retaining unsafe
Lua wrappers, confirms death or two consecutive absences, waits for the zone's
respawn delay, and replaces the missing member only while a live player is
inside the activation radius. No groups are created automatically on startup.
