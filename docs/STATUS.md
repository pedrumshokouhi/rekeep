# Rekeep — Status (15 Oct 2026, end of day)

**Ready to upload.** Everything that can be built and verified on this Mac is done. What's left is App Store Connect setup that only the account owner can do (see bottom).

## Product (version 1.0)

| Platform | What ships |
|---|---|
| Mac | Menu-bar app, glass shelf (⇧⌘V), Library, Compose, Paste Queue, templates, collections with their own shortcuts, settings, onboarding, Shortcuts actions |
| iPhone | Feed with search highlighting, system Paste button, Share extension, **Rekeep keyboard**, Compose, collections, snippets, templates |
| iPad | Sidebar + masonry grid + detail panel, hardware keyboard, drag and drop |
| All | Rekeep Pro (one-time $9.99, non-consumable, universal purchase) |

## Quality control — all passing

| Check | Result |
|---|---|
| Engine unit tests | 26/26 pass |
| Search at 50,000 clips (release) | typical 0.4–75 ms; worst case 109–129 ms when every clip matches |
| Mac capture self-test (real pipeline, private pasteboard) | 20/20 pass; 200 rapid copies in 60 ms |
| StoreKit tests (local App Store config) | 4/4 pass: free limits, price loads, buy → refund revokes → restore, Ask to Buy pending |
| Release builds (Mac, iOS + Share + Keyboard) | succeed; Mac 0 warnings; iOS 2 benign tool notices |
| Contrast (WCAG) | body ≥ 6.2:1, metadata ≥ 5.0:1, white-on-jade buttons 4.6:1 (measured) |
| Largest Dynamic Type (iPhone) | cards reflow; colour labels and glyphs scale |
| Light/dark, iPhone, iPad, Mac renders | reviewed; defects found and fixed (code overflow, image sizing, iPad dimming/overlap, Compose clutter, empty inspector, dark logo, an iPad layout crash on unbounded width) |

## Deliberately not in 1.0

- **iCloud sync.** It can't be verified end-to-end without signing an Apple ID into test devices, and shipping unverified sync risks data loss. The privacy policy already commits that any future sync will be opt-in. Planned for 1.1.
- Link previews (network) and on-device AI features: later, opt-in.

## Not verified on this Mac (needs the owner or a TestFlight pass)

- Live Liquid Glass over real wallpapers (in-process renders show the opaque variant; screen access for the agent was declined).
- Direct paste via Accessibility in the signed App Store build.
- Multi-display placement.

## Owner steps to publish

1. Create the app in App Store Connect: **Apps › + › New App**, platforms **iOS and macOS**, name "Rekeep: Clipboard Manager", bundle ID `com.pedrumshokouhi.rekeep`, SKU `rekeep`.
2. Accept the **Paid Apps agreement** and fill in banking/tax (needed to sell Rekeep Pro).
3. Choose a support email and host `site/rekeep/` at pedrumshokouhi.com/rekeep (replace `SUPPORT_EMAIL`).
4. Provide the App Store Connect API key to the release script (`scripts/release.sh`, reads `ASC_KEY_ID`/`ASC_ISSUER_ID`), or run it yourself.
5. App Privacy: select **Data Not Collected**. Everything else (metadata, screenshots, review notes, IAP) is in `docs/AppStore/`.
