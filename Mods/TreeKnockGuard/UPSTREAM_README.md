# TreeKnockdownSettings

Disable the tree knockdown mechanic on an unofficial **The Isle: Evrima** dedicated server.

The 0.21.77x update introduced destructible foliage — large dinosaurs can knock trees
over by running into them. The mechanic keeps the server busy and causes noticeable
performance hiccups. **There is no `Game.ini` setting to turn it off.**

The configuration lives in a `TArray` named `TreeKnockdownSettings`, carried by the
level's `TIWorldSettings` object. Emptying that array disarms the mechanic. This repo
contains a small UE4SS Lua mod that does exactly that.

*(Version française : [README.fr.md](README.fr.md))*

---

## Requirements

UE4SS installed and working on the **dedicated server** (not the client).

Verified on a Win64 dedicated server, `Gateway` map, build 0.21.77x.

## Target

|              |                                                                                       |
| ------------ | ------------------------------------------------------------------------------------- |
| Object       | `TIWorldSettings` — `/Game/TheIsle/Maps/Game/Gateway/Gateway.Gateway:PersistentLevel.TIWorldSettings` |
| Lookup       | `FindFirstOf("TIWorldSettings")`                                                      |
| Property     | `TreeKnockdownSettings` → `TArray`, **9 entries** on Gateway (opaque `UScriptStruct`)  |
| Lua API      | `Empty()`, `GetArrayNum()`, `ForEach()` — `GetArrayElement`, `RemoveAt`, `Clear` are **not** exposed |

## Install

Copy the `TreeKnockGuard` folder into your server's UE4SS mods directory:

```
<server>\TheIsle\Binaries\Win64\ue4ss\Mods\TreeKnockGuard\Scripts\main.lua
```

Register it in `ue4ss\Mods\mods.txt`:

```
TreeKnockGuard : 1
```

Edit `LOG_FILE` / `OFF_FILE` at the top of `main.lua` to match your install, then
restart the server — a brand-new mod is only enumerated at startup.

> **Tip:** to test without a restart, paste the logic into a mod that is already
> loaded and hot-reloadable. That is how this was developed.

## Verify

In `treeknock.log`:

```
[TreeKnockGuard] loaded, watching TreeKnockdownSettings every 10000ms
[TreeKnockGuard] CLEARED: 9 -> 0
```

In game: charge a large dinosaur into a tree that used to fall. It stays up and
behaves as a solid obstacle again.

## Disable / revert

Create a file named `treeknock.off` next to your log file — the mod stops clearing.

Nothing here is persistent. The array lives in memory only and is repopulated from
the packaged map on every level load; the map files are never touched. Removing the
mod restores stock behaviour completely.

---

## Gotchas worth knowing

These cost real debugging time. If you are writing your own version, read this first.

### 1. `~= nil` does not discriminate

UE4SS returns a **non-nil placeholder** `UObject:` for a property that does not exist.
Four invented names (`FoliageKnockdownSettings`, `TreeFellingSettings`,
`KnockdownSettings`, and a deliberate nonsense control) all came back non-nil during
testing. The only reliable discriminator is the `tostring()` prefix:

| `tostring(value)` | Meaning                                              |
| ----------------- | ---------------------------------------------------- |
| `TArray: 0x...`   | real property, of the stated type                     |
| `UObject: 0x...`  | **does not exist** — any method call throws `Tried calling a member function but the UObject instance is nullptr` |

Always include a deliberately bogus property name as a control in any reflection
probe. Without one, every result is a false positive.

### 2. FName lookup is case-insensitive

`TreeKnockdownSettings` and `TreeKnockDownSettings` resolve to the same array, but each
access allocates a fresh wrapper at a different address. Different addresses do **not**
mean two distinct properties — compare `GetArrayNum()` instead.

### 3. `getmetatable()` returns `false`, not `nil`

These userdata have a protected metatable. An unguarded `rawget(mt, "__index")` throws.
Test `type(mt) ~= "table"`.

### 4. Clearing once is not enough

The array is repopulated from the packaged map on every level load, so a single
`Empty()` at boot does not survive a restart or a map change. Hence the periodic
re-check loop.

### 5. Game thread only

`LoopAsync` runs on a UE4SS worker thread; touching UObjects there races the engine and
causes access violations. Use `LoopInGameThreadWithDelay` when available:

```lua
local schedule = LoopInGameThreadWithDelay or LoopAsync
```

---

## Untested: the no-mod route

The `Game.ini` header carries `UseCommands=true`, so Unreal's array-command syntax is
active. **If** the property is flagged `config` on the C++ side, this would be enough,
with the server stopped:

```ini
[/Script/TheIsle.TIWorldSettings]
!TreeKnockdownSettings=ClearArray
```

This has **not** been verified, and it probably does not work — the people who
documented the mechanic first went through the GObject rather than an ini. But it costs
one restart to find out, and if it works it needs no code at all. Reports welcome.

## Credits

The `TreeKnockdownSettings` / `WorldSettings` lead came from the Evrima server-hosting
community. This repo is the verified, reproducible write-up of it.

## License

MIT — see [LICENSE](LICENSE).
