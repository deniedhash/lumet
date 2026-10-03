# Lumet

A GPS speedometer and navigation head-up display for Android, meant to sit face-up on the dashboard and reflect off the windshield. Black background, glowing numbers, no buttons.

Mounted the other way — upright on a stand, screen toward the driver, unmirrored — the rear camera happens to point straight through the windshield. So it is also a dashcam, with [YouTube Live as the storage](#dashcam).

Package: `com.deniedhashtag.lumet`

## What's on screen

```
 3:28 AM                     ● LIVE                         GPS ●
 Mon, 28 Sep               12:04 · 2.4 Mb/s              ±3 m · 1.4/s

            ↰                                              ARRIVAL
         700 m              ╭───────────╮                   4:16
  Turn right onto           │    72     │               26 min · 17 km
  Outer Ring Road           ╰─  km/h  ──╯

  ▲ HEADING    ⏱ AVG      📏 DISTANCE    ⏲ DURATION    ⛰ ALTITUDE
    NE           68 km/h     12.6 km       00:24         255 m
```

Four gestures, no buttons on the HUD itself:

| Gesture | Does |
|---|---|
| **Tap anywhere** | Toggles mirroring — read it normally in your hand, mirrored once it's reflecting off glass. Also stops recording after a few seconds' grace, because face-up on the dash means the camera is looking at the roof. |
| **Long-press anywhere** | Disarms the dashcam for the rest of the trip, and again re-arms it. |
| **Tap the `● LIVE` block** | Opens [Recordings](#recordings) — past drives and the clips still on the phone. |
| **Long-press the `● LIVE` block** | Mutes or unmutes the microphone. |

Starting a recording has no control at all. See [Dashcam](#dashcam) for why.

## Requirements

- Flutter 3.44.8 or newer, Dart SDK `^3.12.2`
- Android only
- **A physical phone.** An emulator reports speed `0` unless you play a simulated route through Extended controls → Location.

For the dashcam, additionally: a YouTube channel with live streaming enabled, and a stream key — see [One-time setup](#one-time-setup-youtube-stream-key).

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

Then enable **Lumet** in the list. Location permission, by contrast, is requested normally on first launch. Camera and microphone are requested by tapping the dim `Tap to enable dashcam` prompt — never on first launch, where they would stack behind the location dialog, and never while driving.

Thermal behaviour can be forced rather than waited for:

```bash
adb shell cmd thermalservice override-status 2   # MODERATE, also 3 and 4
adb shell cmd thermalservice reset
```

## Dashcam

Unmirrored, the rear camera faces the road. Lumet encodes it to H.264 and pushes it to **YouTube Live as an unlisted broadcast over RTMPS**, which YouTube archives automatically — cloud storage for the footage with no backend to run. A **15-minute rolling buffer** of 60-second MP4 segments is written on the device at the same time, from the same encode, to cover what YouTube cannot: tunnels and dead zones.

There is no camera preview, ever. The HUD looks exactly as it did; the dashcam's entire presence on screen is the `● LIVE` block at the top.

**One drive produces one unlisted video.** See [Splitting](#splitting) for why it is not chopped up.

### Why there is no record button

The HUD reacts to the world rather than being operated: the nav panel appears when a route starts, the label flips to `GPS+IMU` once the forward axis is learned, the GPS dot turns amber as accuracy degrades. Nothing is switched on. Recording follows the same rule — it is derived state:

```
record  ⇔  stream key present
         ∧ camera + microphone granted
         ∧ NOT mirrored
         ∧ moving above the arm threshold
         ∧ NOT manually disarmed
```

It arms at **20 km/h sustained for 5 s**, and stops **5 minutes** after dropping below 3 km/h. The long stop dwell is deliberate: red lights, level crossings and toll booths must not end a broadcast, because every stop/start pair costs a new YouTube archive and a fresh RTMPS handshake.

Losing the fix — a tunnel, a stale stream — **holds** the current decision rather than stopping. That is exactly when you want the camera still rolling.

The one deliberate control is long-press to disarm, for the drive where you would rather not be recording. It clears itself once the car has been parked for the stop dwell, so the next drive arms normally without you having to remember anything.

### The indicator

| Shown | Means |
|---|---|
| `● LIVE` red, glowing | Recording locally and uploading. The detail line carries elapsed time and measured uplink. |
| `● RETRY` amber | Upload dropped, retrying. Still recording locally. |
| `● REC` amber, `local only` | Recording locally, not uploading. Normal in a tunnel. |
| `● REC` dim, `opening camera` | Camera opening, handshake not finished. |
| `● STBY` dim | Ready, waiting for the car to move. |
| `● OFF` dim | Disarmed by long-press. |
| `● DASHCAM` grey | Something is wrong; the detail line says what. |

`·  muted` is appended whenever the microphone is off.

Tap it for [Recordings](#recordings); long-press it to mute.

### Where the footage goes

Segments live in app-private external storage, which needs no storage permission and is removed on uninstall:

```
/sdcard/Android/data/com.deniedhashtag.lumet/files/Movies/dashcam/
```

Since Android 11 the Files app cannot browse `/Android/data`, so `adb pull` is the dev route and the `exportSegments` channel method copies chosen clips into `Movies/Lumet/` where Gallery and Files can see them.

Segments are independent MP4s with identical codec parameters, so they stitch losslessly:

```bash
printf "file '%s'\n" lumet_*.mp4 > list.txt
ffmpeg -f concat -safe 0 -i list.txt -c copy drive.mp4
```

Three independent guards keep the buffer bounded: a segment count for the time window, a 2 GiB byte ceiling in case a bitrate spike outruns that estimate, and a 500 MB free-space floor on the volume. Hitting the floor **stops recording and keeps streaming** — YouTube is the primary store, and your own photos are not ours to evict.

### Splitting

YouTube archives a stream of up to twelve hours, and past that the archive may not be captured at all. Lumet does **not** auto-split anyway, because with a persistent stream key the only available move is to stop the ingest and start it again — and that is precisely the operation YouTube does not guarantee. Reconnect within about ten seconds and the same broadcast resumes; reconnect after thirty or so and the old broadcast ends but the new ingest frequently goes nowhere until the Studio live page is reloaded.

A drive is under twelve hours, so one continuous session is both simpler and safer. The only automatic split is a guard at 11 h 45 m, where the alternative is losing the archive entirely. `splitBroadcast` exists as an explicit, best-effort command — local recording continues across the gap, but check Studio afterwards.

Doing this reliably needs the Live Streaming API, which means OAuth, which means a server. See the note at the end of [One-time setup](#one-time-setup-youtube-stream-key).

### Thermals

The honest power ordering on a phone on a sunny dashboard:

| Source | Approx. |
|---|---|
| Display at full brightness | 2–3 W |
| Sun through glass onto a black phone | large, external |
| Charging waste heat | 1–2 W |
| Sustained cellular uplink | 0.5–1 W |
| Camera sensor and ISP | ~0.7 W |
| Hardware H.264 encode at 720p30 | **~0.2 W** |

The encoder is the smallest term — the HUD's own screen dwarfs it. So there are two responses, and the larger one is not the obvious one: the platform trims the bitrate down a ladder as the thermal status climbs, and Dart drops the screen brightness to 0.6, which is worth more watts than halving the video bitrate. Bitrate changes go through a live `MediaCodec` parameter change, so they never interrupt the stream or start a new segment.

Expect `MODERATE` within 20–40 minutes in direct sun on an `SM-S921B`. At `SEVERE` and above Samsung's camera HAL may refuse or close the camera outright, which is reported as `cameraError`. At `EMERGENCY` the upload stops and local recording continues.

There is one tension with no way out: the HUD's full brightness is the dominant heat source, but the app being visible is also what makes starting a camera foreground service legal.

## One-time setup: YouTube stream key

**1. Enable live streaming on the channel.** YouTube Studio → Create → Go live. The channel needs a verified phone number and no live-streaming restrictions in the last 90 days, and first-time activation can take up to 24 hours. The 50-subscriber rule applies only to streaming from the YouTube mobile app — pushing to RTMPS ingest from your own encoder, which is what this is, has no subscriber minimum.

**2. Set the default visibility to Unlisted.** Studio → Go Live → Stream tab. The app never sends a privacy setting; every broadcast inherits whatever is set there, so this is the step that keeps your drives off the public internet. Check it.

**3. Get the stream key onto the device.** Two ways, and the first needs no copying:

- **Sign in** (see [One-time setup: YouTube account](#one-time-setup-youtube-account)). `liveStreams.list` reports the channel's persistent key *and* its RTMPS address under the same read-only scope the recordings list already uses, so signing in fills both in. It only ever fills a gap — an account that is not the one you stream to cannot quietly replace a working key. **Refresh key** in the Recordings header asks first.
- **By hand**, if you would rather not sign in: tap the dim `Tap to set dashcam key` prompt, paste from Studio, Save.

Either way it lands in the same app-private store and is cached, so a drive never depends on being signed in or having signal. To change or clear it: **tap** the `● LIVE` block → **Stream key**.

A build-time fallback also works, and takes precedence only when nothing has been entered in the app:

```bash
mkdir -p .secrets && pbpaste > .secrets/youtube_key
flutter run -d <device-id> --dart-define=LUMET_INGEST_KEY=$(cat .secrets/youtube_key)
```

Using `$(cat …)` rather than pasting the key into the command keeps it out of your shell history as well as out of git.

> **The stream key is a credential.** Stored on the device it is app-private — safe from other apps, readable with root or a debug backup, which is the same footing as a password saved by anything else. Entered by `--dart-define` instead, it is compiled into the APK, which is fine for a sideload-only app on your own phone and not fine for anything distributed. Never commit it, never paste it into a bug report or a logcat dump, and if it ever leaves the device hit **Reset stream key** in Studio. Nothing in the app logs it: the recorder's own logging is switched off because it would otherwise print the connect URL, and only the ingest *host* is ever reported back to the HUD.

With no key configured, the HUD shows a dim `Tap to set dashcam key` and everything else works exactly as before.

### If this ever moves to a backend

`DashcamConfig.resolveKey()` is the only thing in the app that knows where a key comes from. Replacing its body with an HTTP call is the whole migration — `DashcamSession`, both platform channels and all of the Kotlin are untouched.

Worth being clear about what that buys, though. It does not make the app lighter: the weight is the encoder and the RTMPS client, and those stay on the device. It adds a network dependency at the start of a drive, which is the wrong direction for an offline-first HUD, and whatever authenticates the app to that server also ships in the APK.

Where a server genuinely pays off is the **write** half of the Live Streaming API. The app already signs in read-only to list drives, but creating broadcasts is a different matter: a server holding the refresh token could mint a per-drive unlisted broadcast, hand back a fresh ingest URL and the archived video id, set a real title, and make [splitting](#splitting) reliable — none of which a persistent key can do. That is a real improvement and a different project.

## Recordings

Tap the `● LIVE` block. Two sections, because they answer different questions.

**On YouTube** — every drive the channel has broadcast, newest first, with the live one pinned to the top. Tapping one opens its watch page. A drive whose privacy is anything other than `unlisted` is labelled as such, so a misconfigured default is visible rather than silent.

This is the one part of the app that needs an account. An unlisted video is playable by anyone holding the link, but nothing public can *enumerate* unlisted videos — they appear in no search, no channel page and no public uploads playlist. That is what unlisted means. Listing your own therefore needs an authenticated call, and with a persistent stream key the app never learns a video id on its own: YouTube mints the broadcast server-side and tells nobody. See [One-time setup: YouTube account](#one-time-setup-youtube-account).

The scope requested is `youtube.readonly` and nothing else. The app pushes to a stream key and has no business editing the account.

**On this device** — the rolling buffer, newest first, with the file currently being written marked. Tapping a clip copies it into `Movies/Lumet/` where Gallery and Files can see it; `/Android/data` has not been browsable since Android 11, so this is what makes a clip reachable without `adb`.

## One-time setup: YouTube account

Needed for the Recordings list, and the easiest way to get the stream key onto the device. Streaming works without it — a key entered by hand is enough.

**1.** In [Google Cloud Console](https://console.cloud.google.com), create a project and enable **YouTube Data API v3** under APIs & Services → Library.

**2. OAuth consent screen** → External. Add your own Google account under **Test users** and leave the app in *Testing*. `youtube.readonly` is a sensitive scope: in Testing it works for your test users with no Google verification and no API compliance audit. Publishing the consent screen would trigger both.

**3. Credentials → Create OAuth client ID → Android:**

- Package name: `com.deniedhashtag.lumet`
- SHA-1: the fingerprint of whichever keystore you build with. For the debug keys:

```bash
keytool -list -v -keystore ~/.android/debug.keystore \
  -alias androiddebugkey -storepass android -keypass android | grep SHA1
```

**4.** Create a **Web application** client ID in the same project, and build with it:

```bash
flutter run -d <device-id> --dart-define=LUMET_GOOGLE_CLIENT_ID=<web-client-id>
```

A client id is not a secret — it ships in every app that signs in with Google, and the Android client is matched by package name and signing certificate rather than by anything embedded in the APK. The client *secret* is never needed here and must not go in the app.

> In Testing mode refresh tokens expire after **seven days**, so expect to sign in again about weekly. That is a property of the consent screen's publishing status, not of the app. It costs nothing but the recordings list: the stream key is cached on the device, so recording and uploading carry on regardless.

## Telemetry sidecar

Speed and position are written alongside the footage rather than burned into the video, so the stream stays a clean view of the road. One JSON Lines file per session, next to the segments and sharing their session stem:

```
{"t":1759412711002,"ev":"start","session":"20261002-140511","tz":330,"app":"1.0.0+1"}
{"t":1759412711412,"lat":12.971599,"lon":77.594566,"spd":18.4,"gps":17.9,"hdg":112,"alt":255,"acc":3.2,"trip":12643}
{"t":1759412715002,"ev":"segment","file":"lumet_20261002-140511-0002.mp4"}
{"t":1759412783551,"ev":"mute","on":true}
```

The `start` event is the anchor: an offset into the YouTube archive plus its `t` gives the moment to look up. About 110 bytes per fix at 1.4 fixes/sec, so roughly 550 kB an hour — nothing next to the video.

JSON Lines rather than GPX for one reason that matters in a car: power is lost mid-recording, and every finished NDJSON line survives that where an unclosed `<gpx>` does not. GPX also has nowhere to put accuracy, the fused speed, or mute and segment events without resorting to `<extensions>`. Converting afterwards on a desktop is ten lines of Python.

Absent values are omitted rather than written as `null`, so a consumer never has to guess whether `"hdg":null` means "no heading" or "heading zero". Telemetry stops while the app is backgrounded — the isolate is throttled and the position stream has no foreground notification — and records an explicit `gap` rather than drawing a straight line through the hole.

## Architecture

| File | Role |
|---|---|
| `lib/main.dart` | HUD widget, layout, gauge `CustomPainter` |
| `lib/speed_fusion.dart` | GPS + accelerometer state estimator |
| `lib/nav_link.dart` | Dart side of the notification bridge, ETA parsing |
| `lib/hud_glow.dart` | The one shared visual helper, so the gauge and the indicator cannot drift |
| `lib/dashcam_link.dart` | Dart side of the dashcam bridge; flattens the platform's state for the UI |
| `lib/dashcam_config.dart` | Dashcam constants, and the only thing that knows where a stream key comes from |
| `lib/dashcam_arming.dart` | Pure policy: should the dashcam be running right now |
| `lib/dashcam_retention.dart` | Pure rule: which sidecar files to prune |
| `lib/telemetry_sidecar.dart` | JSON Lines writer, sink injected so it is testable |
| `lib/rec_indicator.dart` | The `● LIVE` block, scoped so it does not ride the 30Hz repaint |
| `lib/stream_key_editor.dart` | Full-screen key entry. Not a dialog: in landscape the IME covers one |
| `lib/recordings_view.dart` | Past drives and on-device clips |
| `lib/youtube_account.dart` | `youtube.readonly` sign-in, `liveBroadcasts.list` and `liveStreams.list` |
| `android/.../NavListener.kt` | `NotificationListenerService`, matches on `CATEGORY_NAVIGATION` |
| `android/.../MainActivity.kt` | All four channels; owns the dashcam commands because a camera service may only start while visible |
| `android/.../dashcam/DashcamService.kt` | Foreground service, owns the stream, implements `ConnectChecker` |
| `android/.../dashcam/SegmentStore.kt` | Rolling buffer: rotation, the three prune guards, MediaStore export |
| `android/.../dashcam/ThermalGovernor.kt` | Bitrate ladder against thermal status and uplink congestion |
| `android/.../dashcam/DashcamBridge.kt` | Static sink and replay, so the service can outlive the Flutter engine |
| `android/.../dashcam/DashcamState.kt` | The state map that crosses the channel. Carries no stream key, ever |
| `android/.../dashcam/DashcamConfig.kt` | Session config; the only place the ingest URL and key are joined |
| `android/.../dashcam/DashcamNotification.kt` | Channel and builder for the ongoing notification |
| `android/.../dashcam/DashcamPermissions.kt` | Camera, microphone and notification grants |
| `android/.../dashcam/DashcamKeyStore.kt` | The stream key, in app-private preferences |

Channels: `lumet/nav` + `lumet/nav_control` for navigation, `lumet/dashcam` + `lumet/dashcam_control` for the recorder.

Dart dependencies: `geolocator`, `sensors_plus`, `wakelock_plus`, `screen_brightness`, plus `google_sign_in` and `http`. Recording itself added **none** — the platform side owns the buffer directory, the permission dialogs, the key store and even opening a URL. The two that are there exist solely to list your own unlisted broadcasts, which cannot be done unauthenticated. Android adds `RootEncoder` (camera → H.264 → RTMPS, from JitPack) and `androidx.core`.

No state management package, no DI. The only backend is YouTube: RTMPS for the bytes, and one read-only Data API call to list what it kept.

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

Sources are symbol names rather than line numbers: symbols do not rot, and the table otherwise needs hand-fixing after every edit.

| Thing | Value | Source |
|---|---|---|
| Gauge scale maximum | 200 km/h | `main.dart` · `_maxScaleKmh` |
| Speed colour: green / amber / red | <80 / <120 / ≥120 km/h | `main.dart` · `_arcColour` |
| GPS dot: green / amber / red | ≤10 m / ≤25 m / >25 m | `main.dart` · `_fixColour` |
| Fix considered stale | 5 s | `main.dart` · `_stale` |
| Trip distance accuracy gate | 25 m | `main.dart` · `_onPosition` |
| Heading considered valid above | 5 km/h | `main.dart` · `_headingValid` |
| Fusion drift clamp | ±6 m/s | `speed_fusion.dart` · `_maxDrift` |
| Fusion noise deadband | 0.15 m/s² | `speed_fusion.dart` · `_deadband` |
| Dashcam arms above | 20 km/h | `dashcam_arming.dart` · `startKmh` |
| ...sustained for | 5 s | `dashcam_arming.dart` · `startDwell` |
| Dashcam stops below | 3 km/h | `dashcam_arming.dart` · `stopKmh` |
| ...sustained for | 5 min | `dashcam_arming.dart` · `stopDwell` |
| Grace before mirroring stops it | 5 s | `dashcam_arming.dart` · `mirrorGrace` |
| Skip the arm dwell if away under | 60 s | `dashcam_arming.dart` · `resumeWindow` |
| Rolling buffer window | 15 min | `dashcam_config.dart` · `bufferMinutes` |
| Segment length | 60 s | `dashcam_config.dart` · `segmentSeconds` |
| Buffer byte ceiling | 2 GiB | `dashcam_config.dart` · `maxBufferBytes` |
| Free-space floor | 500 MB | `dashcam_config.dart` · `minFreeBytes` |
| Video | 720p30 H.264, 2 s keyframes | `dashcam_config.dart` · `width`/`fps` |
| Video bitrate | 2.5 Mbps (≈1.2 GB/hour) | `dashcam_config.dart` · `videoBitrate` |
| Ingest address | from the account, else `rtmps://a.rtmps.youtube.com/live2` | `dashcam_config.dart` · `resolveIngestUrl` |
| Audio | AAC 128 kbps stereo | `dashcam_config.dart` · `audioBitrate` |
| Brightness when throttling | 0.6 | `dashcam_config.dart` · `throttledBrightness` |
| Reconnect backoff | 2 s doubling, capped at 10 s | `DashcamService.kt` · `onConnectionFailed` |
| Archive guard | 11 h 45 m | `DashcamService.kt` · `ARCHIVE_GUARD_MS` |
| Thermal bitrate ladder | 1.0 / 1.0 / 0.7 / 0.45 / 0.3 | `ThermalGovernor.kt` · `ladder` |

The video bitrate sits below YouTube's recommended 3–8 Mbps band for 720p30, which is a deliberate trade against mobile data. It is the first thing to raise — 4 Mbps, about 1.85 GB/hour — if number plates turn out illegible, and since the encoder costs about 0.2 W that is a data decision rather than a thermal one.

`0` and `--` mean different things. `0` is a measured standstill; `--` means no fix, no velocity in the fix, or a stale stream.

## Known limitations

**Never tested while moving.** Everything was verified parked at 0 km/h. `GPS+IMU` has never engaged, because learning the forward axis needs real accelerate/brake cycles. This is the biggest open risk.

**No fix indoors.** `forceLocationManager` drops wifi and cell blending, so you often get nothing at a desk. Deliberate — a wifi-derived position carries no velocity anyway — but surprising if you forget.

**Nav parsing is string-based.** Android hands over display text meant for humans, so `"700 m"` and `"9 min · 3.3 km · 3:20 am ETA"` are parsed with regex. A Maps wording change or a non-English locale breaks it silently.

**Only the immediate turn is available.** Next-next maneuver and lane guidance are not in the notification — they reach head units over the Android Auto protocol, which needs a certified signed receiver. Getting them would mean doing the routing ourselves (e.g. Mapbox Directions `bannerInstructions`).

**No vehicle data.** Android Auto is a projection protocol; data flows to the car, not from it. Speed from the wheels, RPM or fuel would need an OBD-II dongle over Bluetooth.

**The dashcam has never recorded a moving car either.** Same caveat as the speedometer, and for the same reason.

**The archive is only as good as the cellular link.** `local only` is the normal state in a tunnel or a dead zone, and the rolling buffer is the only copy of those minutes. It holds fifteen.

**The camera arms itself on every drive** without an explicit act, which is deliberate — see [why there is no record button](#why-there-is-no-record-button) — and is why the indicator is always visible while recording.

**The stream key is plaintext inside the APK.** Fine for a sideload-only app on your own phone; not fine for anything distributed.

**Roughly 1.2 GB of mobile data per hour** at the default bitrate.

**Sustained encode plus upload may thermally throttle, and may out-draw a car charger.** The app trims bitrate and dims the screen in response, but it cannot win against direct sun.

**Telemetry has holes whenever the app is backgrounded**, marked with a `gap` event.

**`splitBroadcast` is best-effort** and may not produce a new broadcast. See [Splitting](#splitting).

**Segments are not browsable from the Files app** — `/Android/data` has been off limits since Android 11. Use `adb pull`, or tap a clip in [Recordings](#recordings) to copy it into `Movies/Lumet/`.

**Listing drives needs a sign-in, and it lapses weekly.** Unlisted videos cannot be enumerated without an account, and a Testing-mode consent screen expires refresh tokens after seven days. Streaming and recording are unaffected either way — the account is only ever used to read a list.

**The recordings list shows broadcasts, not arbitrary uploads.** It reads `liveBroadcasts`, so anything uploaded to the channel by other means will not appear.

## Publishing

Not currently publishable as-is. `BIND_NOTIFICATION_LISTENER_SERVICE` is restricted by Play policy to apps whose *core purpose* is notification handling — a speedometer reading another app's nav data is the case they reject.

The dashcam compounds this. `CAMERA`, `RECORD_AUDIO` and a typed foreground service each bring their own Play declarations, and the Data safety answer changes materially: audio and video **are** transmitted off the device, to YouTube. Using YouTube as a storage backend for unlisted personal footage is also a grey area in its own right — low risk for one person's own drives, considerably more exposed in anything shipped.

The account sign-in adds one more gate: an app distributed with a sensitive YouTube scope needs its consent screen published, which means Google verification **and** a YouTube API Services compliance audit. Staying in Testing avoids both and is the right call for a sideloaded app.

Options: keep sideloading, or split into Gradle product flavours — one with the listener and the dashcam for personal use, one without for Play.

If it ever does ship:

- Ship an `.aab` (`flutter build appbundle`), not an APK
- Generate a release keystore, keep `key.properties` out of the repo, and enrol in Play App Signing so a lost upload key is recoverable
- Privacy policy URL is mandatory because the app uses location
- Declare location in the Data safety form. "Processed on device, not shared" was the honest answer before the dashcam; it is not any more, because video and audio leave the device
- `applicationId` is permanent; it's already correct

## Licence

JetBrains Mono is bundled under the SIL Open Font License 1.1 — see `assets/fonts/OFL.txt`.
