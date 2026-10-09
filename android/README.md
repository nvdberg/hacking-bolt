# Working-Bolt — Android

Native Kotlin + Jetpack Compose port of the SwiftUI app in `../hacking-bolt-ios`.
Same Lightning Bolt reads, same unit taxonomy, same conflict rules — no server, no stored password.

> **Start each session by reading [`IOS-SYNC.md`](IOS-SYNC.md)** — the running record of what the iOS
> app does now, the current parity target, and which recent changes to port (vs skip as owner-only).

## Build & run

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

./gradlew :app:assembleDebug      # APK → app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:installDebug       # install on the attached device/emulator
```

Emulator (already created on this Mac):

```bash
emulator -avd wb_pixel7_a34 &
adb wait-for-device
adb shell am start -n com.nvdberg.workingbolt/.MainActivity
adb logcat -s WorkingBolt:I     # the app's own harvest log
```

Toolchain: JDK 17 (Homebrew `openjdk@17`), Android SDK 34 + build-tools 34, AGP 8.5.2,
Gradle 8.9, Kotlin 1.9.24, Compose BOM 2024.06. `local.properties` points `sdk.dir` at the
Homebrew SDK and is git-ignored — regenerate it on another machine.

## Layout

| Android | iOS counterpart |
| --- | --- |
| `model/Models.kt` | `Models.swift` — `UnitKey`, `Units`, `MyShift`, `OpenShift`, `Assignment`, `SwapEvent` |
| `model/ConflictEngine.kt` | `ConflictEngine.swift` — `MinInterval`, `MyScheduleModel.flag()` |
| `data/Raw.kt`, `data/Builders.kt` | `DataLayer.swift` — `RawSlot`, `OpenShiftBuilder`, `SwapBuilder` |
| `data/LBWebSource.kt` | `LBWebSource.swift` — login WebView + harvest |
| `data/Store.kt` | the `Snapshot`/`LogSnapshot` disk cache in `HackingBoltApp.swift` |
| `data/DemoData.kt` | `DemoData.swift` |
| `AppViewModel.kt` | `AppModel` in `HackingBoltApp.swift` |
| `ui/PoolScreen.kt` + `ui/MiniMonth.kt` | `PoolView.swift`, `MiniMonth.swift` |
| `ui/CalendarScreen.kt` + `ui/RosterCalendar.kt` | `CalendarView.swift`, `MonthGrid.swift` |
| `ui/WhoScreen.kt` + `ui/WhoShared.kt` | `WhoView.swift` |
| `ui/CrewScreen.kt` | `CompareView.swift` |
| `ui/SettingsScreen.kt` | `SettingsView`/`AdvancedView`/`ExportView` in `Quips.swift` + `Export.swift` |
| `ui/StatsScreen.kt` + `model/ShiftStats.kt` | `StatsView`, `StatsCard`, `CollapsibleMonthCard` in `Stats.swift` |
| `data/ShiftExport.kt` | `ShiftExport` in `Stats.swift` (CSV + .ics; no PDF) |
| `ui/SwapScreen.kt` + `ui/SwapCalendar.kt` + `model/SwapOption.kt` | `SwapFinder.swift` |
| `ui/GiveAwayWizard.kt` | `GiveAwayWizard.swift` |
| `ui/LaunchScreen.kt` + `ui/QuipStore.kt` | `LaunchScreen.swift` + `QuipStore`/`QuotesView` in `Quips.swift` |
| `ui/Theme.kt` | `Theme.swift` |
| `ui/DoctorsOnCall.kt` | `DoctorsOnCall.swift` |
| `ui/CafeteriaScreen.kt` | `CafeteriaView.swift` |
| `ui/GuideScreen.kt` | `Guide.swift` (keep in step — every user-visible change) |
| `data/UpdateChecker.kt` | `UpdateChecker.swift` (gist `wb-android.json`) |

## How the Lightning Bolt read works

Identical to iOS: one WebView holds the real LB session (the user types their password on Lightning
Bolt's own page — the app never sees it). A document-start script wraps `XHR`/`fetch` so the Bearer
the SPA sends to `lbapi` lands in `window.__lbAuth`; we then run the *same JavaScript as the iOS app*
against `schedule/range` to read the open-offer pool, my roster, the whole-group history and
`/personnel`. The injected JS is copied verbatim so both clients stay in lockstep.

Two platform differences worth knowing:

- **No `callAsyncJavaScript`.** Android's `evaluateJavascript` only returns synchronous values, so
  async JS bodies resolve through a `@JavascriptInterface` bridge that streams the result back in
  256 KB chunks (`LBWebSource.evalAsync`). A single bridge string truncates on the multi-megabyte
  group-year payloads.
- **Document-start injection** uses `WebViewCompat.addDocumentStartJavaScript` when the installed
  WebView supports it, falling back to `onPageStarted`.

## What's ported

Pool (with mini-month strip, conflict flags, in-app accept), My Shifts month grid, Who's Working,
Crew, My Stats, Export, More/Advanced (default tab, "For me" default, Who's On row order), demo mode,
the durable shift log, group-history backfill, and the disk cache.

**My Stats** carries Month-by-month (collapsible), Monthly average, Coming up, Year to date, By year
and Custom range, in a user-reorderable order. The three iOS cards it does *not* have — "You vs
group", "Unit mix" and "Shift pickups" — are all owner-gated on iOS, so they fall under the exclusion
above rather than being unfinished work.

**Export** writes .ics and .csv into the app's cache and hands them to the system share sheet via a
`FileProvider`. iOS's PDF exports have no counterpart yet.

### Schedule writes — read this before touching them

**Swap or Give Away is the only part of the app that changes anyone's real schedule.** It reaches
Lightning Bolt through four calls in `LBWebSource`: `offerToPerson`, `offerToGroup`, `splitShift` and
`cancelOffer`, all using the logged-in web view's own captured token. The rules:

- Nothing writes without an explicit confirm dialog naming the shift, the date and the recipient.
- A one-to-one offer is a *pending* LB offer — reversible from the done screen until they accept.
- "Just a part" calls `giveAwayPart`, which **splits the shift in Lightning Bolt first** (all pieces
  stay yours), re-harvests for the new segment's slot_id, then offers only that segment. LB only lets
  a *scheduler* merge pieces back, so this is the one genuinely hard-to-undo path — the UI says so.
- A Pasqua Rapid+MSU day is one 24h shift carrying two LB slots (`slotID` + `slotID2`); the give-away
  moves both halves, or one half if you pick Rapid/MSU.
- Eligibility (`eligibleColleagues`) and the swap engine (`swapOptions`) enforce the same rest rules
  as iOS: no post-call, no pre-call, not already working, plus SICU competency from prior SICU shifts.

Demo mode has fake slot_ids and never reaches the network, so the whole flow is safe to click through
with sample data.

## Deliberately excluded — do not add

**There is no owner/admin surface in the Android app, by decision.** The iOS `AdminView`,
`StartScreenSettings`, the owner-only "Shift pickups" stats card and the `hb_show_admin` setting have
no counterpart here, and the supporting plumbing has been removed too: no `isOwner`, no owner emp-id
constant, no `SwapEvent`/`SwapBuilder`, no swap log on disk.

`GROUP_YEAR_JS` is kept verbatim with iOS (both clients must read Lightning Bolt identically), so it
still *reports* changed-hands slots — `fetchGroupShifts` decodes and drops them. Don't reintroduce a
consumer for them.

## Not ported yet

- **iOS build 91** (the next port, versionCode 4): doctors on call + unit/call-room numbers in Who's On,
  the cafeteria menu, the in-app guide, the regrouped More screen — full spec in `IOS-SYNC.md` → 91.
- **PDF exports**, **alternate app icons**, **Feedback**, the **Hennie holiday** card in Advanced.
- Within ported screens: Pool's landscape two-pane layout, and pull-to-refresh on Pool / My Shifts.
- The launch screen is a *reinterpretation*, not a copy: same beats (bolt → "Hacking" struck out →
  "Working" → tagline → cycling quip, tap to skip), but no ECG-trace path animation.

## The "live" backend features — out of scope by decision

The iOS app's Supabase + GitHub Actions plumbing is **not** being ported. Decided 2026-08-08: the
Android build is a full-functioning client, and shift-alert notifications aren't worth the setup.

- **Push for new open shifts.** iOS registers an APNs token in Supabase `devices`; the poller in
  `.github/workflows/refresh.yml` pushes to it. APNs is Apple-only, so Android would need Firebase
  Cloud Messaging — a Firebase project, `google-services.json`, the SDK, a platform column on
  `devices`, and an FCM branch in the poller. Not happening unless asked. The app is simply silent;
  open it to see new open shifts.
- **Supabase offer notes.** iOS mirrors a give-away note into Supabase via `putOfferNote` because LB
  can't carry a note on a *group* offer. Worth knowing: `Supabase.offerNote(slotID:)` has no call
  site even on iOS, so nothing displays these anywhere yet. One-to-one offers carry their note
  through Lightning Bolt itself and already work here.

## Before shipping to a real phone

Done already: predictive back (`enableOnBackInvokedCallback`), edge-to-edge insets, and dense-grid text
pinned via `fixedSp()` so a 130% system font doesn't truncate unit names or wrap the tab labels
(verified on the emulator at font_scale 1.3 + 480dpi — Samsung's common setup).

Still worth doing before it lives on someone's phone for real:

1. **A release build with a real keystore.** Debug APKs work for sideloading but are debuggable and
   can't be upgraded over by a differently-signed build. Generate one keystore, keep it safe, add a
   `signingConfigs` block, and ship `assembleRelease`. Also try `isMinifyEnabled = true` once — the
   R8 keep rule for the WebView JS bridge is already in `proguard-rules.pro`, but it needs testing.
2. **Bump compileSdk/targetSdk to 35** if the phone is on Android 15 (S24/S25, One UI 7). Not needed
   for sideloading, but Android 15 enforces edge-to-edge for targetSdk 35 and it's better to find any
   inset surprises here than on her phone.
3. **Test the real Lightning Bolt login on-device.** The WebView JS bridge is the one genuinely
   device-dependent piece. `DOCUMENT_START_SCRIPT` needs a reasonably recent WebView (fine on any
   modern Galaxy) and there's an `onPageStarted` fallback, but nothing beats one real sign-in.
4. **"Install unknown apps"** must be allowed for whichever app she opens the APK with.

Not a concern: background/battery restrictions (the app does no background work) and notification
permissions (it sends none).

## Shipping a build to a tester

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
./gradlew :app:assembleRelease        # → app/build/outputs/apk/release/app-release.apk
```

Signed with `signing/working-bolt-release.jks` (git-ignored — **back it up**, see `signing/README.md`).
Copy the APK somewhere versioned by hand, e.g. `../dist-android/WorkingBolt-1.0-b<N>.apk`, and bump
`versionCode` in `app/build.gradle.kts` for every build you hand out — Android refuses to install an
APK whose versionCode is lower than the one already on the phone.

Current hand-out (2026-10-09): **1.0 (versionCode 7) = iOS build 97 parity** (day-card doctors), published as
GitHub release `android-b7` on `nvdberg/hacking-bolt` with the asset `WorkingBolt.apk` (sha256 `22698bfe…f298a7`),
and `wb-android.json` bumped to 7 so b5/b6 phones get the Update banner. Testers get ONE permanent link that
downloads the APK directly (no GitHub page):
`https://github.com/nvdberg/hacking-bolt/releases/latest/download/WorkingBolt.apk`
(Dropbox was dropped: its phone app previews the file instead of downloading it, and fails if the tester's
Dropbox is full.) Local copy `../dist-android/WorkingBolt-1.0-b7.apk`. Previous: `android-b6` (versionCode 6 = iOS 96).

**In-app update (versionCode 5, 2026-10-06).** `data/UpdateChecker.kt` reads
`wb-android.json` (`{"latestBuild": N, "url": "https://…apk"}`) from the public gist; the banner's Update tap
downloads the APK, checks it is this package and a newer versionCode, and installs it through `PackageInstaller`
(permissions `REQUEST_INSTALL_PACKAGES` + `UPDATE_PACKAGES_WITHOUT_USER_ACTION`; Android only accepts the same
signing key). First update: the phone's "Allow from this source" switch, once. After that one tap, no prompt on
Android 12+; the app closes and is reopened by hand. Nothing installs without the tap. `url` must point at the
**.apk** (not the zip); Dropbox share links are turned into direct downloads (`dl=1`) by the app.
To publish a build (each step needs Nicolaas's go): `gh release create android-b<N> <dir>/WorkingBolt.apk -R
nvdberg/hacking-bolt` (asset must be named `WorkingBolt.apk`, release not a prerelease, so the permanent link
follows it), then set `latestBuild` + `url` (the tag's own download URL) in the gist's `wb-android.json`.
"latest" is the repo's newest release — don't publish non-Android releases there without re-pointing testers.
Emulator-tested (API 34): 5→6→7 against a local feed, then real b5 → b6 from the live gist + GitHub URL, and a
fresh install of b6 from the permanent link in Chrome.

**Getting it to a tester:** send the permanent link above. On the phone they tap it, confirm the browser's
"download anyway", open the download, allow
"Install unknown apps" for whichever app opened it, and may have to tap through a Play Protect
"unknown developer" warning ("More details" → "Install anyway"). That warning is expected for
sideloaded apps and doesn't mean anything is wrong.

Later builds install straight over the top **as long as they're signed with the same keystore**. If
the signature ever changes she must uninstall first, which wipes her local shift log and Lightning
Bolt session.

If hand-delivering builds gets tedious, **Firebase App Distribution** is the light-touch upgrade: a
free Firebase project, upload the APK, invite her by email, she gets update notifications. It needs
no SDK in the app and no FCM — it's just hosting, unrelated to the push work we're not doing.

## Testing notes for a tester

1. Install the debug APK and open it. You should land on Lightning Bolt's own sign-in page.
2. Tap **Explore with sample data** first — that walks every screen with no login, which is the
   quickest way to check layout on a real device.
3. Then sign in with real credentials. First run does one full harvest ("Setting up — reading your
   roster…"); after that the Pool refreshes every 2 minutes and the full harvest every ~30.
4. Worth poking at specifically: rotation (the Who's On / Crew landscape week grid is a different
   layout), scrolling the multi-year Who's On timeline, and whether the session survives killing and
   reopening the app.
5. `adb logcat -s WorkingBolt:I` prints how many open shifts / roster slots each read returned —
   useful if a screen looks empty.
