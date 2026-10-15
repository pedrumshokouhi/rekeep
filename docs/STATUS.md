# Rekeep — Status (15 Oct 2026)

Working name: **Rekeep** — *Copy once. Keep moving.* No App Store conflicts on Mac or iOS (checked 15 Oct). Domain and trademark checks still to do.

## What works today (verified)

| Area | State | Evidence |
|---|---|---|
| Shared engine (RekeepKit) | Done | 27 unit tests pass (`swift test` in RekeepKit) |
| Search at 50,000 clips | Typical 0.4–75 ms, worst case 107–127 ms (term in every clip) | release-mode benchmark test |
| Mac capture → store → reuse | Done | in-app self-test: 20/20 pass, 200 rapid copies in 60 ms |
| Mac quick shelf | Done (glass, keyboard, ⌘1–9, preview, templates, queue, multi-select) | in-process renders, light + dark |
| Mac Library (grid/list, filters, inspector, collections, snippets, Compose, Queue) | Done | builds; rendered |
| Mac Settings + onboarding | Done | builds |
| Mac Release build (sandbox + hardened runtime) | Clean, zero warnings | `xcodebuild -configuration Release` |
| App icon (Icon Composer, layered glass) | Done, Mac + iOS, light/dark/tinted/clear | `scripts/make_icon.py --render` |
| iPhone app | Done (feed, search, scopes, Paste button, swipe/long-press, detail, Compose, settings, onboarding) | simulator screenshots |
| iPad app | Done (sidebar, grid, detail panel, keyboard nav) | simulator screenshots |
| Share extension | Builds and embeds | not yet exercised end-to-end in the simulator |

## Not done yet

1. **iPhone keyboard extension** (insert saved clips from any app).
2. **iCloud sync** between Mac and iPhone/iPad. Today each device keeps its own library; the UI says "Saved on this device".
3. **Purchases** (StoreKit 2: free tier + Pro) and paywall.
4. **Siri Shortcuts actions** (App Intents) and widgets.
5. **Optional link previews** (network, opt-in) and on-device AI features.
6. **On-screen QA on the Mac**: live Liquid Glass over real wallpapers, direct paste with Accessibility, multi-display. In-process renders can't capture live glass; screen access for the agent was declined, so this needs either your approval or a manual pass.
7. **App Store submission package**: screenshots from the app, metadata, privacy policy page, reviewer notes, TestFlight.

## Owner actions needed before release

- Apple Developer Program: confirm membership is active (team RMZ2B524CF is signing builds).
- App Store Connect: create the app record (bundle ID `com.pedrumshokouhi.rekeep`, universal purchase Mac + iOS), accept the Paid Apps agreement before Pro.
- Register App Group `group.com.pedrumshokouhi.rekeep` and the iCloud container (Xcode can do this with your account signed in).
- Decide final name (Rekeep vs. alternatives) and pricing.
- A support URL and a privacy-policy URL (can live on pedrumshokouhi.com).

## Known limitations (by platform design)

- **macOS**: macOS asks before any app reads the clipboard in the background. Users must set Rekeep to *Always Allow* in Privacy & Security › Paste from Other Apps. Rekeep shows the current state and links there.
- **macOS**: pasting directly into the frontmost app needs Accessibility permission; without it Rekeep copies and the user presses ⌘V. Rekeep never claims a paste succeeded.
- **iOS**: no background clipboard capture. Rekeep offers the system Paste button (no prompt) when the clipboard changes while it's open, plus the Share sheet.
- Secret detection is heuristic and incomplete; the UI says so.
- The library is protected by macOS/iOS account security and FileVault/Data Protection; Rekeep adds no separate encryption and claims none.
