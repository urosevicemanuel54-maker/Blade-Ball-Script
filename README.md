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

## Performance (FFlags)

The frame limit is not a setting the client exposes — it is one engine flag that the task scheduler reads each frame:

```lua
setfflag("DFIntTaskSchedulerTargetFps", "10000")
```

`10000` removes the cap. The client then renders as fast as it can, bounded by the display. Anything from `60` to `240` is a real cap, `0` or a very high number is effectively none.

Graphics flags, applied by **Low Graphics**:

| Flag | Value | Effect |
|---|---|---|
| `DFIntDebugFRMQualityLevelOverride` | `1` | forces the renderer to quality level 1 (of 21) |
| `FIntRenderShadowIntensity` | `0` | kills shadows |
| `FIntFRMMinGrassDistance` / `FIntFRMMaxGrassDistance` | `0` / `0` | no grass |
| `FIntRenderGrassDetailStrands` | `0` | no grass strands |
| `DFFlagTextureQualityOverrideEnabled` | `true` | enables the texture override |
| `DFIntTextureQualityOverride` | `0` | lowest textures |
| `FFlagDisablePostFx` | `true` | no bloom / DOF / colour correction |
| `FIntRenderLocalLightUpdatesMax` / `Min` | `1` / `0` | fewer dynamic lights |
| `FFlagDebugSkyGray` | `true` | flat sky, skips the skybox pass |

All of these go through `setfflag`, so the executor has to expose it. If it does not, the panel says so once and the toggles do nothing — nothing crashes.

**Limits worth knowing**

- On iOS the renderer is vsynced to the display: uncapped means "as fast as the panel runs", which is 60 Hz on most iPhones and 120 Hz on ProMotion models. No flag gets past that.
- Sustained max FPS on a phone means heat, then thermal throttling, then the frame rate dropping below what a moderate cap would have held. `120` is usually the better setting for long sessions.
- Some flags are only read at startup. If a graphics change does not take effect, restart Roblox and re-execute.
- The **FPS Cap** survives **UNLOAD** on purpose; Low Graphics is restored to the values it captured before the script changed them.

**Desktop equivalent** — same flags in `%LOCALAPPDATA%\Roblox\Versions\<version>\ClientSettings\ClientAppSettings.json`:

```json
{
  "DFIntTaskSchedulerTargetFps": "10000",
  "DFIntDebugFRMQualityLevelOverride": "1",
  "FIntRenderShadowIntensity": "0",
  "FIntFRMMinGrassDistance": "0",
  "FIntFRMMaxGrassDistance": "0",
  "FIntRenderGrassDetailStrands": "0",
  "DFFlagTextureQualityOverrideEnabled": "True",
  "DFIntTextureQualityOverride": "0",
  "FFlagDisablePostFx": "True",
  "FIntRenderLocalLightUpdatesMax": "1",
  "FIntRenderLocalLightUpdatesMin": "0",
  "FFlagDebugSkyGray": "True"
}
```

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

`Perf` (separate table, same file):

| Key | Default | Meaning |
|---|---|---|
| `Unlimited` | `true` | sets the FPS flag to 10000 instead of `TargetFps` |
| `TargetFps` | `120` | cap used when `Unlimited` is off |
| `LowGraphics` | `true` | applies the graphics flag set on load |

## Verification status

Nothing here was run against a live Blade Ball server — this device has no Roblox client. What is verified is the code paths and API usage by inspection: attribute names (`realBall`, `target`), the `zoomies` part and `VectorVelocity`/`AssemblyLinearVelocity` access, remote scanning and firing via `pcall`, and the UI construction.

Two things to check on the first live run:

1. Whether `Remote:FireServer()` with no arguments registers a parry. If the header stays on the correct remote but parries do not register, the remote expects arguments — switch `argMode` in the script to `1` or `2` (or set `OverrideRemote` and test from there).
2. Whether the server rate-limits parry spam. If you see parries stop registering or the account gets flagged, drop `Burst` to 1 and raise `Cooldown` to `0.25`.

Serverside anti-cheat behavior is obfuscated and changes between updates; no client script can guarantee a specific detection outcome.
