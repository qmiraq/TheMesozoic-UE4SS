# DinoStorage Unpark Architecture

## v0.12.15 guarded growth and universal needs

Unpark issues one native growth operation, then observes growth and all
growth-dependent capacities without writing. The first authoritative target
reading permanently latches success. One native retry is allowed only when
four consecutive valid readings prove that growth remained at its original
value; partial movement, conflicting readings, or a target previously seen
must never trigger another growth write.

After growth and capacity stability, every inventory source uses the same
final-needs reconciliation. This includes real parked snapshots,
administrator-created dinosaurs, shop/token dinosaurs, and legacy
percentage-backed rows. A freshly resolved pawn and fresh `NutrientsStruct`
are used after the deferred boundary, followed by thirst, `FoodValue`, and
`Hunger` last. Verification failure leaves the operation uncertain and does
not authorize another growth write.

## v0.12.11 final-needs invariant

For real parked snapshots, the last needs phase runs only after the final
growth and nutrient writes. It restores `FoodValue` first and `Hunger` last.
These are separate GAS-backed attributes; setting only `Hunger` can leave the
food backing value stale and cause a delayed hunger correction on a later game
tick.

This file is the non-negotiable restore contract for The Mesozoic. Future
changes must follow the upstream EVRIMA research in:

- https://github.com/diplomatic-tendencies/evrima-dev-knowledge/blob/main/EVRIMA_DinoStorage_Architecture.md
- https://github.com/diplomatic-tendencies/evrima-dev-knowledge/blob/main/EVRIMA_State_Restore_Cookbook.md
- https://github.com/diplomatic-tendencies/evrima-dev-knowledge/blob/main/EVRIMA_QuestMutation_Fix.md
- https://github.com/diplomatic-tendencies/evrima-dev-knowledge/blob/main/EVRIMA_EntombBonus_Fix.md
- https://github.com/diplomatic-tendencies/evrima-dev-knowledge/blob/main/EVRIMA_Customizer_Field_Map.md

## Invariants

1. Transform an existing, live, naturally spawned same-species juvenile.
2. Never call `RequestRespawn` or any game-save function.
3. Parked, administrator-created, and shop inventory rows use the same restore
   writers and ordering after one compatibility normalization step for legacy
   percentage-only shop rows.
4. Administrator-created replacements always keep the player's current
   location, even if the saved-location button was selected.
5. Re-resolve the controller and pawn by SteamID before every delayed phase.
   Reject the operation if the pawn address, species, or alive state changes.
   Permit only one active restore pipeline per SteamID; a second command must
   be rejected instead of allowing overlapping delayed growth writes.
6. Growth is its own phase. Write the authoritative saved ratio with
   `pawn:SetGrowth`, immediately follow it with the same target through
   `TIGameModeBase:Grow` so EVRIMA recalculates species/growth capacities, then
   require two consecutive matching live-growth readings. If native Grow
   acknowledges before the pawn adopts the target, correct the drift with
   `SetGrowth` only, up to three times; never repeat the native Grow operation
   inside settle retries. Treat growth within 0.5 percentage points as settled
   so normal live growth cannot trigger another correction. Re-resolve the pawn
   before every reading and retry. Only then
   expand percentage-backed snapshots against the settled species maxima. Restore
   `MaxHunger`, `MaxFood`, `MaxThirst`, and `MaxStamina` before current vitals.
   Then restore the full prime struct, quest unlocks, inherited mutation fields,
   nutrients, and repeat the max/current vital pass. The max-vital writes apply
   only to genuinely captured parked snapshots. Administrator/shop percentage
   rows never write maxima because an early live reading can still be the
   juvenile capacity; the game remains authoritative for those maxima.
7. At +250 ms after the post-growth phase, defensively merge quest mutation
   unlocks again.
8. At +500 ms after the post-growth phase, write all 16 mutation FName fields
   directly and push the live
   replicated struct. Never use the per-slot mutation setter APIs.
9. After mutation fields: reapply vitals and nutrients, then elder replication
   stacks, skin, and the optional saved transform. Run the same combined
   `SetGrowth` plus native `TIGameModeBase:Grow` stage once more for both parked
   and administrator/shop dinos, including its stable-reading checks and
   bounded direct-value corrections. Then re-resolve the pawn and reapply the captured Prime
   struct. At effectively 100% saved growth, preserve EVRIMA's live post-Grow
   Condition 7 because full-growth infertility is an expected native
   transition; all other Prime conditions remain snapshot-backed. Reapply every
   captured current vital, including thirst, health, blood, stamina, food, and
   hunger. Apply nutrients next and repeat hunger last because the nutrient
   write can replace hunger/food backing values. Percentage-backed
   administrator/shop rows use the native `SetNutrientSlotValue`, `SetThirst`,
   and `SetHunger` game operations in that same final phase so the settled live
   pawn resolves its own species/growth capacities. Immediately before those
   operations, refresh every expected maximum and current value from the final
   live pawn. Verify only after another 750 ms. If that verification catches a
   late growth rollback, correct growth directly and retry the stable-reading,
   Prime, and needs sequence up to two times. A retry must always restore final needs
   after its last growth write; never leave a growth call after final needs.
10. Use direct `pawn.CustomizerData` field writes followed by
    `pawn:ForceNetUpdate()`. Never pass customizer data by value.
11. Verify growth, all mutation slots, full prime state, quest unlocks, elder
    stacks, alive state, vital ratios, and nutrient ratios before reporting
    success. For saved-location restores, the successful transform application
    stage is authoritative; do not reject a correct teleport later because
    collision, terrain snapping, or player movement changed the coordinates.
12. Consume the inventory row only after the verified success result.

The authoritative implementation is `Scripts/main.lua`. The Discord-side
transaction and administrator-location normalization are in
`bot/services/dino_storage_service.py`.

If an upstream document refers only to “safety rule N” without the rule’s full
context already present, stop and ask the user for that context before changing
the implementation.
