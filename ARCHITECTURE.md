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

## App entry and photo ingest (current)

On first entry, the app sets up SQLite, asks for a **Current Home** (Location auth), then **automatically indexes** the Photo Library and builds events. After that, later launches with a populated library do **not** pick up new/edited photos by themselves — re-run **Index Photos** from Developer/Settings. There is no Photos change observer or change-token sync.

### Phase 1 — Process start (every launch)

```
MagicFrameApp → ContentView → LibraryViewModel.init
  → AppContainer.shared → DatabaseManager.bootstrapSchema
ContentView.onAppear
  → LibraryViewModel.onAppear → runStartupPipeline
  → VisionJobCoordinator.startIfNeeded  (queued Vision jobs only; does not index Photos)
```

1. `MagicFrame/MagicFrameApp.swift` opens `ContentView`.
2. `MagicFrame/ContentView.swift` creates `LibraryViewModel`, which materializes `AppDependencies` / `AppContainer`.
3. Container bootstrap runs schema migrations (including dropping legacy occasion tables).
4. UI is `MagicFrame/Views/MainTabView.swift`: Home + Settings (Developer console).
5. On appear: `LibraryViewModel.onAppear()` → `runStartupPipeline()`, and the Vision worker starts.

### Phase 2 — Startup decision tree

In `LibraryViewModel.runStartupPipeline()`:

| Condition | What happens |
|-----------|----------------|
| No Current Home | Show home onboarding; **stop** (no Photos index yet) |
| Home + indexed photos + events | Lightweight status only; load home counts. **No auto index/sync** |
| Home but 0 photos or 0 events | `continueLibraryBootstrap()` |

### Phase 3 — First-time home onboarding

Presented as a full-screen cover from `ContentView` when `showHomeOnboarding` is true.

1. Location lookup / pin confirm (Core Location — **not** Photos yet).
2. User taps **Continue & Import Photos**.
3. Home saved → `homeOnboardingCompleted()` → `continueLibraryBootstrap(reindexAfterHomeSetup: true)`.

### Phase 4 — Index Photos (first import or manual re-index)

Triggered automatically when `indexedPhotoCount == 0`, or manually via Developer → Index Photos (`LibraryViewModel.indexPhotosFromLibrary()`).

1. `PHPhotoLibrary.requestAuthorization(for: .readWrite)` — first Photos prompt.
2. `enumeratePhotoLibrary` — full fetch of image assets (last 100 years).
3. For **every** asset: `PhotoDatabase.upsertPhoto(...)` keyed by `localIdentifier`.
4. SQLite `INSERT … ON CONFLICT(id) DO UPDATE` in `PhotoRepository`:
   - New id → insert
   - Existing id → overwrite PhotoKit fields (`modificationDate` stored, but **not used as a change gate**)
   - Clears soft-delete flags; refreshes `lastSeenAt` / `indexedAt`
   - Does **not** clear `eventAssignedAt` (already-assigned photos stay assigned)

**New vs modified in practice:** both are upserts. There is no differential detection.

### Phase 5 — Immediate post-index work (automatic after index)

Still inside `indexPhotosFromLibrary()` / bootstrap:

```
Full PhotoKit upsert
  → Metadata enrichment (AlbumImportService, PhotoTextMetadataImportService)
  → PeopleImportService → rebuildEventPeople
  → performEventSync(forceMaintenance: true)
       → GPS assign / cluster batches (eventAssignedAt IS NULL)
       → No-GPS metadata assignment passes
       → Post-sync maintenance
            → Location links + merges
            → Covers + event_people
            → Enqueue geocode queue
```

Vision object recognition does **not** run on this path; it is later (holiday collection expand / Developer rescan). Holiday AI tagging no longer runs via occasion scoring.

### Phase 6 — Later launches and library changes

- If home + photos + events already exist, startup returns early — no re-enumeration.
- New camera rolls / edits in the Photos app are **not watched**.
- To ingest them today: Developer → **Index Photos** (full re-upsert), then Sync/Rebuild as needed for unassigned photos.
- Soft-delete helper `markPhotosDeletedIfMissing` exists but is **not called** from the index path, so Photos deletions are not cleaned up automatically.

### Manual knobs (Settings / Developer)

- **Index Photos** — re-run full upsert
- **Sync Events** — assign remaining `eventAssignedAt IS NULL`
- **Rebuild Events** — heavier reset/rebuild path
- Geocode batch, holiday scoring, Vision rescan, etc.

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

## Holidays (tags + birthdays)

Holidays no longer use an `occasions` / `event_occasion_scores` system.

- **Landing catalog:** built-in `EventAttributeField.holidayType.builtInOptions` plus people with a non-empty `birthDate`.
- **Event filtering:** `EventListFilter.holidayTag` / `.anyHoliday` via `event_tags` (`tagCategory = holiday`); birthdays via `.birthdayPerson(personId:displayName:)` using `people.birthDate` ±3 days.
- **Vision object scans:** `ObjectDetectionCategory` hardcodes Christmas/Halloween/(Mother’s|Father’s Day) object keys. Landing Vision configs come from those categories (no DB occasions).
- **Dropped tables (migration):** `occasion_landing_metrics`, `occasion_collection_events`, `photo_occasion`, `occasion_subjects`, `event_occasion_scores`, `occasion_scoring_rules`, `occasion_dates`, `occasions`.

## Migration approach (high level)

- Extract `SQLiteDatabase` + `SQLiteMigrations` first (no behavior change).
- Introduce repository protocols and SQLite implementations that wrap existing SQL.
- Extract services (Photos, geocoding, event sync) to isolate Apple frameworks and pipelines.
- Introduce ViewModels; convert Views to call ViewModel intents.
- Move debug utilities into `Debug/` and keep production layers clean.
