# Sentinel — Blade Ball remote parry engine

A Luau auto-parry that fires the game's own parry `RemoteEvent` instead of synthesizing mouse input. The upstream template this started from is kept at [reference/upstream-template.luau](reference/upstream-template.luau); it only does `VirtualInputManager:SendMouseButtonEvent`, which is slow and dependent on the click being accepted in the same frame.

## What it does differently

| | Upstream template | Sentinel |
|---|---|---|
| Parry input | `VirtualInputManager` mouse press | `Remote:FireServer()` on the discovered parry remote |
| Ball detection | first `realBall` child | nearest incoming ball by time-to-impact, multi-ball aware |
| Timing | fixed `distance / speed <= 0.55` | configurable window + half-RTT latency compensation + per-target bonus |
| Retry | none | burst fires (1–5, configurable spacing) after the first shot |
| Extra | notification | event-driven early shot on target lock, highlight, trajectory line, keybind, status HUD |

## Remote discovery

The parry remote name is not stable across game updates, so the script resolves it at runtime instead of hard-coding it:

1. `Config.OverrideRemote` if set (dot path, e.g. `ReplicatedStorage.Remotes.Parry`).
2. Otherwise it scans every descendant of `ReplicatedStorage` for a `RemoteEvent` / `UnreliableRemoteEvent` and scores the name:
   - exact `parry` → 120
   - contains `parry` → 92 (104 if it also contains `request` or `remote`, +4 for `client`)
   - contains `deflect` → 70
   - anything below 70 is refused — it will not guess and fire an unrelated remote.
3. Re-scans if the resolved instance is destroyed, and every 2 s while it is still unresolved.

The resolved full path is shown in the GUI header and in the status panel. If it ever resolves to the wrong remote, put the correct path into `Config.OverrideRemote` and press **RESCAN REMOTE**.

## Firing

`Remote:FireServer()` is tried with three argument shapes in order: no arguments, `(ballPart)`, `(ballPart, position)`. A failing shape drops back to no arguments. If remote firing fails entirely and `FallbackToMouse` is on, it falls back to the upstream `VirtualInputManager` press.

## Timing

```
eta     = distance / ballSpeed
window  = Config.Window + ping/2 (when PingCompensation) + 0.05 (when the ball targets you)
parry   = eta <= window, gated by Config.Cooldown
```

`eta` is computed from `HumanoidRootPart` to the ball's `zoomies` part, using `AssemblyLinearVelocity`, and only when the ball is closing on you (dot product of the offset and velocity > 0.2).

Defaults: `Window = 0.62`, `Cooldown = 0.12`, `Burst = 2`, `BurstGap = 0.03`.

## Usage

1. `Sentinel.luau` is hosted in this repository (public, raw).
2. In an executor with `loadstring`, `game:HttpGet` and `Drawing` (optional):

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/urosevicemanuel54-maker/Blade-Ball-Script/main/Sentinel.luau"))()
```

[loader.luau](loader.luau) is the same thing with the URL at the top, if you prefer to keep one short line in your executor.

Re-executing unloads the previous instance first (the API handle lives at `getgenv().Sentinel`). **Right Shift** toggles auto-parry, **UNLOAD** tears down the GUI, connections, highlight and Drawing line.

## Config reference

| Key | Default | Meaning |
|---|---|---|
| `AutoParry` | `true` | master switch |
| `UseRemote` | `true` | fire the parry remote |
| `FallbackToMouse` | `true` | mouse press if remote firing fails |
| `PingCompensation` | `true` | widen the window by half RTT |
| `EventHook` | `false` | fire immediately when a ball's `target` attribute becomes you (within `EventHookRange`) |
| `EventHookRange` | `220` | studs |
| `Window` | `0.62` | seconds-to-impact at which the first parry fires |
| `Cooldown` | `0.12` | minimum seconds between parries |
| `Burst` | `2` | total fires per parry event |
| `BurstGap` | `0.03` | seconds between burst fires |
| `TrackUntargeted` | `true` | also consider balls not yet flagged as targeting you |
| `Highlight` | `true` | highlight the incoming ball |
| `Trail` | `true` | Drawing line from you to the ball |
| `OverrideRemote` | `""` | dot path override for the parry remote |
| `ToggleKey` | `RightShift` | auto-parry toggle |

## Verification status

Nothing here was run against a live Blade Ball server — this device has no Roblox client. What is verified is the code paths and API usage by inspection: attribute names (`realBall`, `target`), the `zoomies` part and `VectorVelocity`/`AssemblyLinearVelocity` access, remote scanning and firing via `pcall`, and the UI construction.

Two things to check on the first live run:

1. Whether `Remote:FireServer()` with no arguments registers a parry. If the header stays on the correct remote but parries do not register, the remote expects arguments — switch `argMode` in the script to `1` or `2` (or set `OverrideRemote` and test from there).
2. Whether the server rate-limits parry spam. If you see parries stop registering or the account gets flagged, drop `Burst` to 1 and raise `Cooldown` to `0.25`.

Serverside anti-cheat behavior is obfuscated and changes between updates; no client script can guarantee a specific detection outcome.
