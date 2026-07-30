# Magic Frame

A native iOS app that indexes your Photo Library into local SQLite, clusters photos into events and trips, geocodes locations, and scores holidays/occasions (with Apple Vision) so memories can be curated for display on a frame.

*Your memories. Beautifully displayed.*

## Requirements

- Xcode (iOS SDK)
- iOS **18.0+**
- Photo Library access
- Location When In Use (home onboarding map)

## Open & run

1. Open `MagicFrame.xcodeproj` in Xcode.
2. Select an iPhone/iPad simulator or device.
3. Build and run the `MagicFrame` scheme.

There are no SPM or CocoaPods dependencies; the app links system `libsqlite3`.

## What’s working

| Area | Status |
|------|--------|
| Photo indexing → SQLite | Working (Developer / Settings) |
| Event sync (GPS + time + metadata attach) | Working |
| Geocoding & locations | Working |
| Home → Collections, Holidays, Locations | Working |
| Occasion scoring + Vision object scans | Working (developer tooling included) |
| Home → Trips, People, Activities | Coming soon |
| End-user Settings (vs Developer console) | Not yet |

## Current product priority

**Finish Holidays / frame curation** before Trips/People home tiles or major event-assignment pipeline changes (streaming GPS import, non-GPS year buckets).

See [ARCHITECTURE.md](ARCHITECTURE.md) for the target layered architecture, event assignment plans, and occasion scoring design.

## Project layout

```
MagicFrame/
  Domain/          Pure models and scoring helpers
  Persistence/     SQLite database + migrations
  Repositories/    Data access
  Services/        Photos, Geocoding, Events, Occasions, Vision
  ViewModels/      Screen orchestration
  Screens/         Event/location/developer UI
  Views/           Home tabs and occasion UI
  Debug/           Dev database + Vision label tools
```

Composition root: `MagicFrame/AppContainer.swift`.

## Branch note

Active development for occasions, Vision, and home UI lives on `occasions-vision-home` (branched from the layered-folder reorg on `main`).
