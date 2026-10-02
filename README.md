# Lumet

A GPS speedometer and navigation head-up display for Android, meant to sit face-up on the dashboard and reflect off the windshield. Black background, glowing numbers, no buttons.

Package: `com.deniedhashtag.lumet`

## What's on screen

```
 3:28 AM                                                    GPS ●
 Mon, 28 Sep                                             ±3 m · 1.4/s

            ↰                                              ARRIVAL
         700 m              ╭───────────╮                   4:16
  Turn right onto           │    72     │               26 min · 17 km
  Outer Ring Road           ╰─  km/h  ──╯

  ▲ HEADING    ⏱ AVG      📏 DISTANCE    ⏲ DURATION    ⛰ ALTITUDE
    NE           68 km/h     12.6 km       00:24         255 m
```

Tap anywhere to toggle mirroring — read it normally in your hand, mirrored once it's reflecting off glass.

## Requirements

- Flutter 3.44.8 or newer, Dart SDK `^3.12.2`
- Android only
- **A physical phone.** An emulator reports speed `0` unless you play a simulated route through Extended controls → Location.

Developed against a Galaxy S24 (`SM-S921B`), Android 15.

## Build and run

```bash
flutter pub get
flutter run -d <device-id>                                   # hot reload
flutter build apk --debug --target-platform android-arm64    # ~7s incremental
```

Restricting to `android-arm64` matters: the default builds a fat APK for three ABIs and takes minutes instead of seconds.

### Launching over adb

```bash
adb shell am start -n com.deniedhashtag.lumet/.MainActivity
```

**Never launch with `adb shell monkey`.** It arms rotation events as part of its setup, which flips `settings system accelerometer_rotation` to `1` and leaves it there. This looks exactly like the app turning on auto-rotate by itself, and it isn't — verified by isolation: idle stays `0`, `am start` stays `0`, monkey launching *any* app flips it to `1`.

## One-time setup: notification access

The navigation panel reads the ongoing notification that Google Maps posts while a route is running. That permission cannot be requested with a dialog — it has to be granted by hand.

Tap the dim `Tap for nav access` prompt in the app, or:

```bash
adb shell am start -a android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS
```

Then enable **Lumet** in the list. Location permission, by contrast, is requested normally on first launch.

## Architecture

| File | Role |
|---|---|
| `lib/main.dart` | HUD widget, layout, gauge `CustomPainter` |
| `lib/speed_fusion.dart` | GPS + accelerometer state estimator |
| `lib/nav_link.dart` | Dart side of the notification bridge, ETA parsing |
| `android/.../NavListener.kt` | `NotificationListenerService`, matches on `CATEGORY_NAVIGATION` |
| `android/.../MainActivity.kt` | `EventChannel` `lumet/nav`, `MethodChannel` `lumet/nav_control` |

Dependencies: `geolocator`, `sensors_plus`, `wakelock_plus`, `screen_brightness`. No state management package, no DI, no backend.

### How the speed works

`Position.speed` is derived from **Doppler shift** on the satellite carrier frequencies, not from dividing distance by time. That's why it stays accurate even when the position itself is off by several metres.

Two deliberate choices raise the update rate:

- `intervalDuration: 200ms` — this becomes `setMinUpdateIntervalMillis`, which is a *floor*. Setting it to 1s was capping delivery at 1Hz.
- `forceLocationManager: true` — bypasses the fused provider, which batches and throttles. The legacy `LocationManager` hands over each raw GPS fix as it lands.

Together these took the observed rate from 1.0 to **~1.4 fixes/sec** outdoors.

`SpeedFusion` fills the gaps between fixes. Each GPS fix snaps the estimate to truth; between fixes, acceleration is integrated forward at 50Hz. Error can only accumulate for the gap between two fixes, never longer.

The accelerometer reports in *device* axes, and the app has no idea how the phone sits in your mount — so the forward axis is **learned** rather than calibrated: when GPS says the speed changed by some amount, whichever direction the phone felt acceleration in during that window must be forward. Each window nudges the estimate by 25%, so one noisy sample can't redefine which way forward is.

The corner label reads `GPS` until the axis is learned, then `GPS+IMU`.

## Thresholds

| Thing | Value | Source |
|---|---|---|
| Gauge scale maximum | 200 km/h | `main.dart:15` |
| Speed colour: green / amber / red | <80 / <120 / ≥120 km/h | `main.dart:239-240` |
| GPS dot: green / amber / red | ≤10 m / ≤25 m / >25 m | `main.dart:221-222` |
| Fix considered stale | 5 s | `main.dart:208` |
| Trip distance accuracy gate | 25 m | `main.dart:167` |
| Heading considered valid above | 5 km/h | `main.dart:248` |
| Fusion drift clamp | ±6 m/s | `speed_fusion.dart:27` |
| Fusion noise deadband | 0.15 m/s² | `speed_fusion.dart:23` |

`0` and `--` mean different things. `0` is a measured standstill; `--` means no fix, no velocity in the fix, or a stale stream.

## Known limitations

**Never tested while moving.** Everything was verified parked at 0 km/h. `GPS+IMU` has never engaged, because learning the forward axis needs real accelerate/brake cycles. This is the biggest open risk.

**No fix indoors.** `forceLocationManager` drops wifi and cell blending, so you often get nothing at a desk. Deliberate — a wifi-derived position carries no velocity anyway — but surprising if you forget.

**Nav parsing is string-based.** Android hands over display text meant for humans, so `"700 m"` and `"9 min · 3.3 km · 3:20 am ETA"` are parsed with regex. A Maps wording change or a non-English locale breaks it silently.

**Only the immediate turn is available.** Next-next maneuver and lane guidance are not in the notification — they reach head units over the Android Auto protocol, which needs a certified signed receiver. Getting them would mean doing the routing ourselves (e.g. Mapbox Directions `bannerInstructions`).

**No vehicle data.** Android Auto is a projection protocol; data flows to the car, not from it. Speed from the wheels, RPM or fuel would need an OBD-II dongle over Bluetooth.

## Publishing

Not currently publishable as-is. `BIND_NOTIFICATION_LISTENER_SERVICE` is restricted by Play policy to apps whose *core purpose* is notification handling — a speedometer reading another app's nav data is the case they reject.

Options: keep sideloading, or split into Gradle product flavours — one with the listener for personal use, one without for Play.

If it ever does ship:

- Ship an `.aab` (`flutter build appbundle`), not an APK
- Generate a release keystore, keep `key.properties` out of the repo, and enrol in Play App Signing so a lost upload key is recoverable
- Privacy policy URL is mandatory because the app uses location
- Declare location in the Data safety form — "processed on device, not shared" is the honest answer here
- `applicationId` is permanent; it's already correct

## Licence

JetBrains Mono is bundled under the SIL Open Font License 1.1 — see `assets/fonts/OFL.txt`.
