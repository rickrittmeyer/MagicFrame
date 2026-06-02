# MagicFrame Architecture (Target)

This document describes the **target layered architecture** for MagicFrame and the **dependency rules** that prevent circular dependencies. It’s a guide for future refactors; the current code may not match yet.

## Goals

- Keep SwiftUI views **thin** (render + forward user intent).
- Move orchestration/state into **ViewModels**.
- Hide persistence details behind **Repository protocols**.
- Isolate Apple frameworks (`Photos`, `CoreLocation`, `SQLite3`) inside **Services** and **Persistence**.
- Make “event logic” (matching/clustering) **pure/testable** where possible.
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
- **Does not**: import Services (no “repo → service” direction).
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

Domain is “below” everything and must not import other layers.
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

### “Hard no” rules

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
- `MagicFrame/Repositories/Protocols/LocationRepository.swift`
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

- `MagicFrame/Services/Photos/PhotosAuthorizationService.swift`
- `MagicFrame/Services/Photos/PhotosLibraryService.swift`
- `MagicFrame/Services/Photos/PhotoMetadataBuilder.swift`
- `MagicFrame/Services/Geocoding/GeocodingService.swift`
- `MagicFrame/Services/Geocoding/LocationGeocodeCoordinator.swift`
- `MagicFrame/Services/Events/EventMatchingService.swift`
- `MagicFrame/Services/Events/EventSyncService.swift`
- Event clustering: nested `PhotoDatabase.EventClusteringService` in `PhotoDatabase.swift` (no separate file)
- `MagicFrame/Services/Events/EventPeopleService.swift`
- `MagicFrame/Services/Events/EventCoverService.swift` (optional)
- `MagicFrame/Services/Imaging/PhotoImageService.swift` (optional)

### Debug-only (optional)

- `MagicFrame/Debug/DebugTools.swift`
- `MagicFrame/Debug/DevDatabaseTools.swift`

## Migration approach (high level)

- Extract `SQLiteDatabase` + `SQLiteMigrations` first (no behavior change).
- Introduce repository protocols and SQLite implementations that wrap existing SQL.
- Extract services (Photos, geocoding, event sync) to isolate Apple frameworks and pipelines.
- Introduce ViewModels; convert Views to call ViewModel intents.
- Move debug utilities into `Debug/` and keep production layers clean.

