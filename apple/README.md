# Hope for iPhone and Apple Watch

Stages 8–9 of `docs/rebuild-plan.md`. One Xcode project, two apps, one shared Swift package:

```
apple/
  Hope.xcodeproj      targets: Hope (iOS 18+), HopeWatch (watchOS 11+, embedded in Hope),
                      HopeWidget (the watch-face complication, embedded in HopeWatch)
  HopeCore/           Swift package: records (SwiftData), timer rules, sync engine — no UI; `swift test`
  Shared/             SwiftUI used by both apps, and Localizable.xcstrings (English + 简体中文)
  iOS/                iPhone app: Today, start/pause/resume/stop, account, hands the sign-in to the watch
  Watch/              Watch app: activity list, running screen, writes the complication snapshot
  WatchWidget/        WidgetKit extension: the complication (circular, rectangular, inline, corner)
  Config/             Base.xcconfig, per-target Info.plist additions, Local.xcconfig.example
  scripts/            configure-supabase.sh
```

Bundle IDs: `io.github.dan9574.hope.ios`, `io.github.dan9574.hope.ios.watchkitapp` and
`io.github.dan9574.hope.ios.watchkitapp.widgets`. App icons (`iOS/Assets.xcassets`, `Watch/Assets.xcassets`)
are the desktop icon's ring cropped full-bleed from `src-tauri/icons/icon.icns` with `sips`.

## Version

`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` live in `Config/Base.xcconfig`; the version shows at the bottom
of the watch's activity list ("Hope 2.0.0"). Bump the patch (and the build number) for every build installed
on a device, so the watch can be told apart from the previous one. Keep it equal to the desktop's version.

## Tests

```sh
cd apple/HopeCore
swift test
```

Runs on macOS, no simulator needed. Covers the sync engine against an in-memory fake server (a port of
`src-tauri/src/sync/fake.rs`: two devices converge, offline edits, delete vs edit, one running session,
idempotent pull, pagination, the 50-sequence overlap), the GoTrue/PostgREST request shapes, token refresh,
the timer rules, the wake-up / bedtime day rules (`HopeCore/DayRules.swift`, the port of the desktop's
`src/lib/useToday.ts`: the small hours belong to the day that has not gone to sleep, a day's records run from
last night's bedtime to its own), the duration formats and the complication snapshot.

## Signing (once per machine)

1. `cp apple/Config/Local.xcconfig.example apple/Config/Local.xcconfig` and set `DEVELOPMENT_TEAM` to your
   team ID (the `OU=` field of your "Apple Development" certificate; see the comment in the example).
   `Local.xcconfig` is git-ignored.
2. In Xcode → Settings → Accounts, sign in with that Apple ID. Command-line builds with
   `-allowProvisioningUpdates` use this account to create the development profiles.

The project uses automatic signing. The only capability is an App Group (`group.io.github.dan9574.hope`)
shared by the watch app and its complication; a free personal team provisions it (verified). No push, no
iCloud. With a free personal team, apps installed on a device expire after 7 days and must be re-installed
from Xcode. With the paid Developer Program the profiles last a year (the team has been on the paid program
since 2026-10-12). If Xcode keeps reusing an old 7-day profile after upgrading, delete the cached
`io.github.dan9574.hope*` profiles under `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` and
rebuild with `-allowProvisioningUpdates`; check `embedded.mobileprovision` for `ExpirationDate`.

## Away reminder (stage 11)

With a timer running on an ordinary activity, the iPhone anchors where it started and watches a 300 m
circle around it (`CLMonitor`); leaving it posts a notification with Keep Going / Stop / Not for 30 Minutes,
mirrored to the watch. Switch it on in Account; it asks for notifications and location (When In Use, then
Always — only Always lets the geofence wake the app in the background). The rules are
`HopeCore/AwayReminder.swift` (tested), the plumbing `iOS/AwayMonitor.swift`. Exercise activities
(`kind = 'exercise'`) and the timetable are never anchored. See rebuild-plan section 14.

## Break reminder (stage 12)

Every 90 minutes of running time (the pause chain, pauses excluded) a local notification says "Take a
break" with Pause / A Little Longer. The rules are `HopeCore/BreakReminder.swift` (tested); the scheduler
`Shared/BreakScheduler.swift` runs on both the watch and the iPhone and lines up the next four steps as
`UNTimeIntervalNotificationTrigger`s whenever the store changes, so the system fires them while the app is
suspended. The watch reminds first; the phone two minutes later as a fallback, and drops its own steps
when the watch reports over WatchConnectivity (`WatchLink.sendBreakClaim` → `PhoneLink.onBreakClaim`)
that it has them. "A Little Longer" writes `session.break_ack_ms`, which syncs and settles that step on
every device. Switch: bottom of the watch's activity list, and the iPhone's Account page. Exercise and
timetable activities are never reminded. `Shared/NotificationRouter.swift` is the single notification
delegate; the away reminder registers its category there too. See rebuild-plan section 15.

## Supabase config

The apps read `HopeSupabaseURL` / `HopeSupabaseAnonKey` from their Info.plist. The values come from
`Config/Supabase.generated.xcconfig` (git-ignored), which `scripts/configure-supabase.sh` writes from the
repository's root `.env` — the same file and keys the desktop uses (see `supabase/README.md`):

```sh
apple/scripts/configure-supabase.sh
```

Both targets run the script in `--check` mode as their first build phase. If `.env` changed since the last
build, the phase regenerates the file and stops the build with
"…has been regenerated from .env. Build again to use it." (Xcode had already read the old values.)

With no `.env`, or with either value empty, the apps build and run local-only and Account says
"Not configured". Never put the service-role key in `.env`.

## Build

```sh
cd apple
# iPhone app (builds and embeds the watch app)
xcodebuild -project Hope.xcodeproj -scheme Hope -destination generic/platform=iOS \
  -derivedDataPath build -allowProvisioningUpdates build
# Watch app alone
xcodebuild -project Hope.xcodeproj -scheme HopeWatch -destination generic/platform=watchOS \
  -derivedDataPath build -allowProvisioningUpdates build
```

Products: `apple/build/Build/Products/Debug-iphoneos/Hope.app` (with `Watch/HopeWatch.app` inside) and
`apple/build/Build/Products/Debug-watchos/HopeWatch.app`. To only check that it compiles, add
`CODE_SIGNING_ALLOWED=NO`.

## Run in the simulator

```sh
cd apple
xcodebuild -project Hope.xcodeproj -scheme Hope -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' \
  -derivedDataPath build build
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Hope.app
xcrun simctl launch booted io.github.dan9574.hope.ios
```

For the watch, build the **HopeWatch** scheme for a watchOS simulator and install
`build/Build/Products/Debug-watchsimulator/HopeWatch.app` on it. Add `-AppleLanguages "(zh-Hans)"` to
`simctl launch` to see the Chinese strings.

## Run on a device

The simplest path is Xcode: open `apple/Hope.xcodeproj`, pick the **Hope** scheme and the iPhone, Run.
Installing the iPhone app also installs the watch app on the paired watch (check the Watch app on the
iPhone → My Watch → Hope if it does not appear). To debug the watch app, pick the **HopeWatch** scheme and
the watch.

From the command line (after a signed build above):

```sh
xcrun devicectl list devices
xcrun devicectl device install app --device <iPhone id> apple/build/Build/Products/Debug-iphoneos/Hope.app
xcrun devicectl device process launch --device <iPhone id> io.github.dan9574.hope.ios
```

First launch on the iPhone: Settings → General → VPN & Device Management → trust the developer certificate.
Developer Mode must be on (Settings → Privacy & Security → Developer Mode) on both iPhone and watch.

## Watch-face complication

`WatchWidget/` is a WidgetKit extension inside the watch app with four families:

| | Running | Paused | Idle |
|---|---|---|---|
| Circular | ring in the activity colour, ticking time | dimmed ring, pause symbol, frozen time | Hope ring, today's total (`2 h` / `15 min`) |
| Rectangular | dot + `Parent · Child` (or just the child), large ticking time | same, frozen and grey, "Paused" | Hope ring + "Hope", today's total, "Tracked today" |
| Inline | `Child 12:34` | pause symbol + `Child 12:34` | `Hope · 2 h 15 min` |
| Corner | timer symbol in the activity colour, time on the curve | pause symbol, frozen time | Hope ring, today's total on the curve |

Running time is the whole pause/resume chain without pauses, drawn with a system timer text
(`Text(timerInterval:)`), so the face ticks without timeline reloads. Colour comes only from the activity
palette in full-colour faces; tinted faces use the system tint through `widgetAccentable`. Tapping it opens
the watch app.

Data: the extension never opens the SwiftData store. The watch app (`Watch/ComplicationPublisher.swift`)
writes `widget-snapshot.json` (`HopeCore/WidgetSnapshot.swift`) into the App Group container after every
committed store change (timer actions, pulls that changed data) and when it becomes active, and calls
`WidgetCenter.shared.reloadAllTimelines()` when the face would look different. The idle timeline has a
second entry at local midnight so today's total resets. The SwiftData store itself stays in the app's own
container (`groupContainer: .none`).

One switch, `HOPE_COMPLICATION_LIVE_DATA` in `Config/Base.xcconfig` (override in `Local.xcconfig`): `YES`
(default) adds the App Group entitlement to both watch targets; `NO` builds a launcher-only complication
(Hope ring, opens the app, no live data) with no capability at all.

To add it: on the iPhone, Watch app → Face Gallery or My Faces → pick a face → Complications → Hope; or on
the watch, long-press the face → Edit → swipe to Complications → tap a slot → Hope. Open the watch app once
after installing so it writes the first snapshot.

## How the watch gets signed in

Supabase refresh tokens rotate, and reusing a spent one revokes the whole session, so the iPhone does not
share its own session. When you sign in on the iPhone (and a watch with Hope is paired), it signs in a
second time with the same password and passes that session to the watch over WatchConnectivity
(`updateApplicationContext`). From then on the watch refreshes its own tokens and talks to Supabase
directly. If the watch was added later, use Account → Connect Apple Watch (asks for the password again).
Signing out on the iPhone signs the watch out too. Without an account, both apps are fully local.
