MesozoicPteraStamina alpha v0.1.0

Adds 0.25% of maximum stamina every second to player-controlled Pteranodons.
The bonus applies while gliding, flying, or grounded. It is clamped at 100%.
AI Pteranodons are never enumerated or modified.

Configuration:
  Mods\MesozoicPteraStamina\config\PteraStamina.ini

UE4SS log markers:
  [MesozoicPteraStamina] loaded version=0.1.0-alpha
  [MesozoicPteraStamina] [HEALTH] ...

The feature has no per-tick disk writes. Its one-second tick resolves only
known real-player controllers and skips non-Pteranodon pawns immediately.
