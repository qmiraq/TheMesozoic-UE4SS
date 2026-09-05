The Mesozoic - TreeKnockGuard alpha v0.1.0

Purpose
-------
Disables Evrima's destructible-tree knockdown mechanic by keeping the live
TIWorldSettings.TreeKnockdownSettings array empty.

Runtime behavior
----------------
- Checks the array every 10 seconds on the game thread.
- Clears it only when the game or a level load repopulates it.
- Does not edit the Gateway map or game save files.
- Refuses to use a worker-thread fallback if the safe game-thread scheduler is
  unavailable.

Verification
------------
After restarting the game server, open treeknock.log in this directory. Look
for:

  [TreeKnockGuard] loaded, watching TreeKnockdownSettings every 10000ms
  [TreeKnockGuard] CLEARED: 9 -> 0

Then charge a large dinosaur into a tree that normally falls. It should remain
standing as a solid obstacle.

Temporary kill switch
---------------------
Create an empty file named treeknock.off in this directory and restart or wait
for the next check. Delete treeknock.off to allow clearing again.

Upstream
--------
https://github.com/DevMazzitelli/TreeKnockdownSettings
The upstream license and README are included beside this file.
