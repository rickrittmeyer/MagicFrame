# MagicFrame Architecture (Target)

This document describes the **target layered architecture** for MagicFrame and the **dependency rules** that prevent circular dependencies. It's a guide for future refactors; the current code may not match yet.

## Goals

- Keep SwiftUI views **thin** (render + forward user intent).
- Move orchestration/state into **ViewModels**.
- Hide persistence details behind **Repository protocols**.
- Isolate Apple frameworks (`Photos`, `CoreLocation`, `SQLite3`) inside **Services** and **Persistence**.
- Make "event logic" (matching/clustering) **pure/testable** where possible.
- Avoid circular dependencies by enforcing **one-way imports**.

## Layers

### View (SwiftUI)

- **Owns**: layout, navigation, bindings, basic view-local UI concerns.
- **Does not**: call SQLite, Photos APIs, geocoding, or long-running pipelines directly.
- **Depends on**: `SwiftUI`, `ViewModels`, and optionally `Domain` types for display.

### ViewModel (ObservableObject)

- **Owns**: screen state (`statusText`, events list, loading flags, alerts), UI-friendly formatting, and orchestrates user actions.
- **Does not**: contain raw SQL, `PHAsset` iteration, or `CLGeocoder` calls.
- **Depends on**: `Combine`, `Foundation`, `Domain`, `Repositories/Protocols`, and **service protocols**.

### Repository (protocols + implementations)

- **Protocols**: the API ViewModels use (e.g., `fetchEvents()`, `upsertPhotos(...)`).
- **SQLite implementations**: translate repo calls into SQL using the Persistence layer.
- **Does not**: import Services (no "repo → service" direction).
- **Depends on**:
  - Protocols: `Foundation`, `Domain`
  - SQLite impl: `Foundation`, `Domain`, `Persistence/SQLite`

### Persistence / DB (SQLite)

- **Owns**: database connection, migrations, statement execution, binding helpers.
- **Does not**: know about SwiftUI, ViewModels, or Services.
- **Depends on**: `SQLite3` (+ `Foundation`).

### Services

Services encapsulate external frameworks and heavy pipelines:

- **Photos services**: authorization, asset enumeration, image/thumbnail access (`Photos` / `PHImageManager`).
- **Geocoding services**: reverse geocoding + throttling (`CoreLocation` / `CLGeocoder`).
- **Event pipeline services**: incremental sync, clustering, matching (prefer pure `Domain` logic).

Services may depend on **repository protocols** to read/write data, but repositories must not depend on services.

## Dependency rules (no cycles)

### Allowed dependency flow

```
Views
  ↓
ViewModels
  ↓
Repositories (protocols)  ←  Services (depend on protocols)
  ↓
Repositories (SQLite impl)
  ↓
Persistence/SQLite
  ↓
SQLite3

Domain is "below" everything and must not import other layers.
```

### Import rules (enforced by convention)

- **Domain**: may import `Foundation` only (avoid `SwiftUI`, `Photos`, `CoreLocation`, `SQLite3`).
- **Persistence/SQLite**: may import `Foundation`, `SQLite3` only.
- **Repositories/Protocols**: may import `Foundation`, `Domain` only.
- **Repositories/SQLite**: may import `Foundation`, `Domain`, `Persistence/SQLite`.
- **Services**:
  - May import `Foundation`, `Domain`, `Repositories/Protocols`
  - May import Apple frameworks they wrap (`Photos`, `CoreLocation`, etc.)
  - Must not import `SwiftUI` or `ViewModels`
- **ViewModels**: may import `Foundation`, `Combine`, `Domain`, `Repositories/Protocols`, `Services` (prefer service protocols).
- **Views**: may import `SwiftUI`, `ViewModels` (and optionally `Domain`).

### "Hard no" rules

- **No** `View` → `SQLite3` / raw SQL.
- **No** `Repository` → `Service` imports.
- **No** `Service` → `ViewModel` / `View` imports.
- **No** `Domain` → any app layer imports.

## Proposed future file layout (exact names)

This is the intended end state. Existing files should not be moved until a dedicated refactor step.

### App / Composition root

- `MagicFrame/App/AppContainer.swift`
- `MagicFrame/App/AppEnvironment.swift`

### Views (SwiftUI)

- `MagicFrame/Views/ContentView.swift`
- `MagicFrame/Views/EventDetailView.swift`
- `MagicFrame/Views/PhotoThumbnailView.swift`

### ViewModels

- `MagicFrame/ViewModels/LibraryViewModel.swift`
- `MagicFrame/ViewModels/EventDetailViewModel.swift`
- `MagicFrame/ViewModels/ViewModelSupport.swift`

### Domain (pure)

- `MagicFrame/Domain/Models/Photo.swift`
- `MagicFrame/Domain/Models/Event.swift`
- `MagicFrame/Domain/Models/EventCandidatePhoto.swift`
- `MagicFrame/Domain/Models/PendingLocation.swift`
- `MagicFrame/Domain/Models/Place.swift`
- `MagicFrame/Domain/Geo/GeoDistance.swift`
- `MagicFrame/Domain/Geo/LocationBucketing.swift`
- `MagicFrame/Domain/Errors/AppError.swift`

### Repository protocols

- `MagicFrame/Repositories/Protocols/PhotoRepository.swift`
- `MagicFrame/Repositories/Protocols/EventRepository.swift`
- `MagicFrame/Repositories/Protocols/PeopleRepository.swift`
- `MagicFrame/Repositories/LocationRepository.swift`
- `MagicFrame/Repositories/Protocols/LocationRepository.swift` (future protocol)
- `MagicFrame/Repositories/Protocols/RepositoryTypes.swift`

### Persistence (SQLite)

- `MagicFrame/Persistence/SQLite/SQLiteDatabase.swift`
- `MagicFrame/Persistence/SQLite/SQLiteMigrations.swift`
- `MagicFrame/Persistence/SQLite/SQLiteStatements.swift` (optional)
- `MagicFrame/Persistence/SQLite/SQLiteBindingHelpers.swift`
- `MagicFrame/Persistence/SQLite/RowMappers/PhotoRowMapper.swift`
- `MagicFrame/Persistence/SQLite/RowMappers/EventRowMapper.swift`
- `MagicFrame/Persistence/SQLite/RowMappers/LocationRowMapper.swift`

### Repository implementations (SQLite-backed)

- `MagicFrame/Repositories/SQLite/SQLitePhotoRepository.swift`
- `MagicFrame/Repositories/SQLite/SQLiteEventRepository.swift`
- `MagicFrame/Repositories/SQLite/SQLitePeopleRepository.swift`
- `MagicFrame/Repositories/SQLite/SQLiteLocationRepository.swift`

### Services

- `MagicFrame/Services/Photos/PeopleImportService.swift`
- `MagicFrame/Services/Photos/PhotosAuthorizationService.swift`
- `MagicFrame/Services/Photos/PhotosLibraryService.swift`
- `MagicFrame/Services/Photos/PhotoMetadataBuilder.swift`
- `MagicFrame/Services/Geocoding/ReverseGeocodeParser.swift`
- `MagicFrame/Services/Geocoding/LocationGeocodeCoordinator.swift`
- `MagicFrame/Services/Geocoding/GeocodingService.swift` (optional future facade)
- `MagicFrame/Services/Events/EventMatchingService.swift`
- `MagicFrame/Services/Events/EventSyncService.swift`
- `MagicFrame/Services/Events/EventClusteringService.swift`
- `MagicFrame/Services/Events/EventPeopleService.swift`
- `MagicFrame/Services/Events/EventCoverService.swift` (optional)
- `MagicFrame/Services/Imaging/PhotoImageService.swift` (optional)

### Debug-only (optional)

- `MagicFrame/Debug/DebugTools.swift`
- `MagicFrame/Debug/DevDatabaseTools.swift`

## Event assignment (current + planned)

### Current batch pipeline (Sync Events)

1. **GPS match** — attach to an existing GPS-backed event when time and distance fit tuning.
2. **Time-only cluster (GPS only)** — if no GPS match, attach to (or create) a `clusteredByTimeOnly` event using date/time gaps (`eventMatchMaxGapHours`).
3. **Metadata attach** — no-GPS photos may join existing GPS-backed events when album/people/time signals are strong enough; batches stop when nothing attaches.
4. **Time-only no-GPS** — remaining no-GPS orphans get date/time clustering (same gap tuning as GPS time-only). *Under review: per-year buckets e.g. `Non-GPS Photos (2015)` instead, to avoid thousands of low-value events.*

**Sync Events** and **Run No-GPS Photo Assignment** run steps 3–4 via `syncSecondaryPhotoAssignmentPasses()` (exposed on `PhotoDatabase` as `syncMetadataAssignmentUntilComplete()`).

### Planned: streaming GPS at import

- Process GPS photos in stable chronological order while indexing.
- Compare each photo to the previous GPS photo; on time/distance break, close cluster → **EventScorer** → hide junk → geocode only likely events → holiday/trip tags → append to list.
- Eliminates most overlap issues and defers heavy work until an event is "real."

### Planned: non-GPS strategy (product)

- **Year buckets** — one event per year (`Non-GPS Photos (YYYY)`); users split manually later.
- **Photo-level tags** — holidays and milestones (e.g. birthdays from People/albums) on photos without fake day events.

### Planned: photo-level tags (no-GPS)

- Holidays and milestones on **photos** (with or without year buckets).
- Lets older no-GPS libraries benefit from calendar meaning before users organize manually.

### Planned: manual city/state and trip merge

- DB columns: `userManualCity`, `userManualState`, `userEditedManualLocation` on `events` (UI not wired yet).
- When the user sets the same manual city/state on contiguous day events, merge them into a trip (e.g. "Trip to Orlando") — see `mergeTripsByUserManualLocation()` stub in `EventClusteringService`.

## Occasion scoring (planned)

Recurring date-based occasions (holidays, birthdays, anniversaries). Tables: `occasions`, `occasion_dates`, `occasion_scoring_rules`, `event_occasion_scores`, `photo_object_tags`, `event_object_tags`.

Component scores on `event_occasion_scores` map to rule `signalType` groups below. **`dateScore` is not driven by `occasion_scoring_rules`** — it comes from overlap with `occasion_dates` (and `occasions.defaultWindowDaysBefore/After` when `startDate`/`endDate` are null).

### `signalType` / `signalValue` vocabulary

Rules live in `occasion_scoring_rules (occasionId, signalType, signalValue, score)`. Matching is **case-insensitive** after trim unless noted. Text rules (keyword/album) fire at most once per occasion per event; object rules add `score × photoCount` where `photoCount` is distinct photos with that `objectKey` above min confidence (then component caps apply before `totalScore`).

| `signalType` | `signalValue` format | Writes to | Data source |
|--------------|-------------------|-----------|-------------|
| `object` | `objectKey` | `objectScore` | `event_object_tags.objectKey` (from `photo_object_tags`) |
| `album` | see Album formats | `albumScore` | `photo_albums` → `albums` |
| `people` | see People formats | `peopleScore` | `event_people`, `photo_people`, `occasions.personId` |
| `location` | see Location formats | `locationScore` | `events` + `locations` (city/state/place/home/away) |
| `keyword` | see Keyword formats | `albumScore`* | `photo_text_metadata` (filename, title, keywords) |
| `user` | see User formats | `userScore` | UI / confirmed tags / manual boosts |

\*Keyword rules default into the same component bucket as album/text signals (`albumScore` or a future `textScore`). If we split later, migrate rules only — not `signalValue` strings.

#### `object`

- **`signalValue`:** canonical `objectKey` (snake_case, stable), same as `photo_object_tags.objectKey` / `event_object_tags.objectKey`.
- **Match:** count distinct photos in the event (or trip descendants when scoring a container) with that `objectKey` and `confidence >= minObjectConfidence` (tuning, e.g. 0.25).
- **Score:** `rule.score × photoCount` per object rule (e.g. 3 photos with `christmas_tree` at +0.45 → +1.35 before the 1.0 object cap).
- **Examples:** `christmas_tree`, `pumpkin`, `birthday_cake`, `balloon`, `fireworks`.
- **Display names** belong in `displayName` columns, not in rules.

#### `album`

Album title / person-album linkage. Prefer stable ids where possible.

| Prefix | `signalValue` example | Matches |
|--------|---------------------|---------|
| `id:` | `id:album.localIdentifier` | Exact PhotoKit album id (`albums.albumId`) |
| `title:` | `title:Christmas` | `albums.title` equals or contains (tuning: exact vs contains) |
| `title_contains:` | `title_contains:birthday` | Substring match on normalized title |
| `person_album:` | `person_album:42` | Album linked to `personId` 42 (`albums.personId`) |
| `subtype:` | `subtype:smartAlbumFavorites` | `albums.collectionSubtype` (optional, for smart albums) |

- **High-cardinality albums** (`albums.isHighCardinality = 1`) are ignored unless the rule uses `id:` (same idea as metadata attach).
- **Examples for Christmas:** `title_contains:christmas`, `title:Christmas`, `id:<user’s Christmas album uuid>`.

#### `people`

| Prefix | `signalValue` example | Matches |
|--------|---------------------|---------|
| `person:` | `person:42` | `event_people` or ≥N photos with `photo_people.personId = 42` |
| `person_name:` | `person_name:Vince` | `people.name` on any person linked to event (fallback when id unknown) |
| `occasion_person` | `occasion_person` | `occasions.personId` for this occasion appears in `event_people` (birthdays) |
| `min_people:` | `min_people:2` | Event has at least 2 distinct people (anniversaries, parties) |
| `couple:` | `couple:42,57` | Both person ids present (anniversaries; see `occasions` gap below) |

- **Birthday occasions** should set `occasions.personId` and use `occasion_person` (and optional `person:{id}`) rules.
- **Anniversary occasions** should use `couple:{id},{id}` until a first-class couple model exists.

#### `location`

| Prefix | `signalValue` example | Matches |
|--------|---------------------|---------|
| `home` | `home` | Event centroid within `homeEventSnapMiles` of current home (or designated home for event dates) |
| `away` | `away` | Event is away from home beyond `awayFromHomeMiles` |
| `city:` | `city:Orlando` | `events.city` or linked `locations.city` |
| `state:` | `state:FL` | State match (normalize abbrev vs full name in code) |
| `place:` | `place:Disney World` | `placeName` or location nickname contains value |

- Location is usually a **weak** holiday signal; use low rule scores unless the occasion is place-specific.

#### `keyword`

Cheap text from indexing; scanned across photos in the event.

| Prefix | `signalValue` example | Matches |
|--------|---------------------|---------|
| `filename_contains:` | `filename_contains:christmas` | `photo_text_metadata.originalFilename` |
| `title_contains:` | `title_contains:Halloween` | `photo_text_metadata.assetTitle` |
| `keyword:` | `keyword:birthday` | Entry in `keywordsJson` (if populated) |

- Prefer **contains** matching with normalized lowercase.
- Filename rules are noisy; keep scores lower than album/people signals.

#### `user`

Manual / explicit overrides. Not used for automatic detection logic except replay.

| `signalValue` | Meaning |
|---------------|---------|
| `confirmed` | User confirmed this occasion for this event/year → sets `userScore` to rule `score` (often 1.0) and `isConfirmed` |
| `rejected` | Reserved; prefer `event_occasion_scores.isRejected` column over a rule |
| `boost` | Manual boost (e.g. +0.25) without full confirm |

### `dateScore` (not in `occasion_scoring_rules`)

Computed from `occasion_dates` for scoring year `Y`:

1. Resolve window: `startDate`/`endDate` on `occasion_dates`, else `date` ± `defaultWindowDaysBefore/After` from `occasions`.
2. Compare to event effective range (min/max photo dates in event, or `events.startDate`/`endDate`).
3. Output 0.0–1.0 (e.g. 1.0 if event center falls on `date`, decay by days outside window).

Use `observedDate` when present instead of `date` for “when celebrated” if you want observed-day matching.

### Rule authoring conventions

- **One occasion** = many rules across signal types; **sum** matching rule scores per component, then **cap** each component (e.g. 0.0–1.0) before weighting into `totalScore`.
- **Do not** duplicate the same `(signalType, signalValue)` for one `occasionId` (enforce `UNIQUE(occasionId, signalType, signalValue)` when implementing).
- **Seed holidays** with `object` + `album` + `keyword` rules; **seed birthdays** with `occasion_person` + optional `object:birthday_cake`.
- **`confidence`** on `event_occasion_scores`: derive from `totalScore` bands (`low` / `medium` / `high`), not from individual rules.

### Open schema notes (for later steps)

- **Anniversaries:** `occasions.personId` holds only one person; use `couple:id,id` in rules or add `occasion_people` junction.
- **Movable holidays:** one `occasion_dates` row per year (Easter, Thanksgiving); seed annually.
- **FKs:** `occasion_scoring_rules.occasionId`, `event_occasion_scores.eventId` → parent tables when migrations are added.

## Migration approach (high level)

- Extract `SQLiteDatabase` + `SQLiteMigrations` first (no behavior change).
- Introduce repository protocols and SQLite implementations that wrap existing SQL.
- Extract services (Photos, geocoding, event sync) to isolate Apple frameworks and pipelines.
- Introduce ViewModels; convert Views to call ViewModel intents.
- Move debug utilities into `Debug/` and keep production layers clean.
