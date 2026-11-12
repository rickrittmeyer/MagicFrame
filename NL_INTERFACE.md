# Magic Frame — Natural language interface (spec)

Voice/typed NL is the **query bar**. The answer is always a **visual canvas** (event list, year collection, photo grid, or frame strip). This document is the v1 contract: typed intents, commands the current SQLite graph can already answer, and what is deferred.

No LLM is required for v1. A later model only **fills this schema**; Magic Frame executes it with existing repositories.

## Principles

1. **Photos out, not essays.** Short status line + existing screens.
2. **Typed intent, never raw SQL.** Parser → `NLIntent` → ViewModel navigation/query.
3. **Clarify before mutating.** Show/filter is silent; Add to Frame / Hide needs confirmation.
4. **Say when data is missing.** “I only know people from P- albums.” “That place isn’t linked to events yet.”
5. **App must stay in foreground** for long jobs (index, geocode, Vision) — same as today.

## Result surfaces (reuse, don’t invent)

| Surface | Existing entry |
|---------|----------------|
| All events | `EventsLibraryScreen(filter: .allEvents)` |
| Any holiday | `HolidaysLandingView` or `.anyHoliday` |
| One holiday | `.holidayTag(value:)` e.g. `"Christmas"` |
| Birthday | `.birthdayPerson(personId:displayName:)` (people.birthDate window) |
| Mother’s / Father’s Day | `.holidayTag(value:)` e.g. `"Mother's Day"` |
| One location | `EventListFilter.location(locationId:displayTitle:)` |
| Locations list | `LocationsView` |
| On-frame photos | Event slideshow / `setPhotoShowOnFrame` (no per-occasion frame strip) |
| Person photos | `searchPhotosWithPerson` (ids only — need a photo grid host) |

---

## Intent schema (`NLIntent`)

```text
NLIntent
  action: Show | AddToFrame | RemoveFromFrame | Clarify | Unsupported
  target: Events | Photos | Locations | HolidaysLanding | FrameStrip
  filters:
    holidayTagValue?: String      // event_tags.tagValue, e.g. "Christmas" (holidays use event_tags, not occasions)
    personId?: Int                // people.personId after name resolve; birthdays use people.birthDate
    personNameQuery?: String      // unresolved display / clarify
    locationId?: Int
    placeQuery?: String           // unresolved "St Georgie island"
    year?: Int                    // 2019
    yearRange?: (start: Int, end: Int)
    onFrame?: Bool                // true = already on the frame
    looksLikeObjectKey?: String   // v1.1 — Vision photo_object_tags, not occasion
  sort: DateDesc (default)
  limit?: Int                     // “best 20” — v1.1; v1 ignores or caps display
  utterance: String               // original text for logging
  confidence: Low | Medium | High
  clarify?: ClarifyPrompt         // when action == Clarify
```

`ClarifyPrompt`:

```text
question: String
choices: [{ id, label, resumeIntent }]
```

`Unsupported`:

```text
reason: MissingPeopleGraph | MissingLocationLink | NotIndexed | VideoNotSupported | Ambiguous | Unknown
message: String    // shown + spoken
```

Writes (`AddToFrame` / `RemoveFromFrame`) **must** include a resolved photo-id set from a prior `Show`. v1 does not infer “those” without a current result context.

---

## Entity resolution

### Holidays (high confidence, local dictionary)

Map utterance tokens → `holidayTagValue` (`event_tags`, category `holiday`). Vision category slugs (`christmas`, `halloween`, …) are only for object scans.

| Phrases | holidayTagValue / surface |
|---------|---------------------------|
| christmas, xmas | `Christmas` |
| halloween | `Halloween` |
| easter | `Easter` |
| mother's day, mothers day, mom's day | `Mother's Day` |
| father's day, fathers day, dad's day | `Father's Day` |
| holidays, holiday photos | `.anyHoliday` / Holidays landing |

Birthday: `{name} birthday` / `{name}'s birthday` → person with matching `people.name` and non-empty `birthDate` → `EventListFilter.birthdayPerson(personId:displayName:)`.

Default meaning of “Christmas photos”: **events tagged holiday Christmas** (`event_tags`), not Vision `christmas_tree`. Follow-up: “Include photos that look like Christmas?” → `looksLikeObjectKey` (v1.1).

### People (medium — data-limited)

Resolve `personNameQuery` against `people.name` (case-insensitive, nickname later).

- 0 hits → Unsupported `MissingPeopleGraph`
- 1 hit → `personId`
- 2+ → Clarify

People exist only from albums titled `P-{Name}`. Apple Photos Faces are **not** in the DB.

### Places (medium — depends on `events.locationId`)

Resolve `placeQuery` against `locations.nickname`, `placeName`, `city`, `state` (contains, fold diacritics, strip punctuation). Prefer locations that already have events (`getLocationsRankedByEventCount`).

- 0 hits with events → Unsupported `MissingLocationLink` (even if a GPS bucket exists)
- 1 hit → `locationId` + `.location` filter
- 2+ → Clarify (“St. George Island, FL vs St. George, UT”)

Aliases (seed later, not required for parser v1): `st george island` / `st georgie island` / `st. george`.

### Time (v1: calendar year only)

- Explicit year: `2019`, `in 2019`
- Range: `2015 to 2018`
- “Last Christmas” → current-year holiday collection if past this year’s date, else previous year (v1.1)

Do **not** parse “when the kids were little” in v1 → Clarify.

### Frame

- “on the frame”, “on my frame”, “showing now” → `onFrame: true`
- “not on the frame”, “candidates”, “add to frame from …” → `onFrame: false` on a Show, or `AddToFrame` after a Show

---

## v1 command list (DB can answer today)

Assume holidays have been scored and locations relinked/geocoded. Parser is keyword/phrase, not generative.

### Show — events / landings

| Example utterance | Intent | Execution |
|-------------------|--------|-----------|
| Show me all my photos / collections | Show Events, no filters | `.allEvents` |
| Show me holidays | Show HolidaysLanding | `HolidaysLandingView` |
| Show me Christmas / Christmas photos | Show Events, holidayTag `Christmas` | `.holidayTag("Christmas")` |
| Show Halloween | Show Events, holidayTag `Halloween` | `.holidayTag("Halloween")` |
| Show Easter | Show Events, holidayTag `Easter` | `.holidayTag("Easter")` |
| Show Mother's Day | Show Events, holidayTag | `.holidayTag("Mother's Day")` |
| Show Father's Day | Show Events, holidayTag | `.holidayTag("Father's Day")` |
| Show Rachel's birthday | Show Events, birthdayPerson | `.birthdayPerson` after name → personId |
| Show me Christmas 2019 | Show Events, holiday + year 2019 | holiday filter, then expand/scroll year (existing year accordion) |
| Show locations | Show Locations | `LocationsView` |
| Show me St. George Island / trips to St. George | Show Events, locationId | `.location` if resolved |
| What's on the frame for Christmas | Show Events/Photos, holiday + onFrame | Christmas-tagged events’ on-frame photos |
| Photos of Rachel | Show Photos, personId | `searchPhotosWithPerson` → photo grid (thin new host over existing thumbnails) |
| Photos of Rachel on the frame | Show Photos, personId, onFrame true | photos of that person currently marked on-frame in events; else Unsupported with explanation |

### Mutate — only with current result set + confirm

| Example | Intent | Execution |
|---------|--------|-----------|
| Add these to the frame | AddToFrame (context photo ids) | existing `setPhotoShowOnFrame` |
| Remove this from the frame | RemoveFromFrame | existing remove APIs |

v1 confirm copy: “Add 24 photos to the frame?”

### Clarify / unsupported (expected)

| Utterance | Result |
|-----------|--------|
| Pictures of Mom | Clarify if multiple people, or MissingPeopleGraph |
| St Georgie island | Fuzzy place; Clarify if 2 locations |
| All my trips | Unsupported until trip containers (`parentEventId` / `isTripEvent`) are populated — say so |
| Show videos | `VideoNotSupported` |
| Photos with a Christmas tree | v1.1 object key; v1: “I can show Christmas events. Tree detection comes next.” |
| Show pickleball | Activities not modeled as a first-class filter (custom `activityType` exists on events — **v1.1** `event_tags` / `activityType`) |

---

## v1 parser (no LLM)

Pipeline:

1. Normalize: lowercase, strip punctuation, expand `xmas` → `christmas`.
2. Detect **action** (show default; add/remove if those verbs + “frame”).
3. Detect **slot** hits from dictionaries (holiday tag values, year regex, on-frame phrases, person names from `people`, place tokens ≥ 3 chars against location strings).
4. If ≥2 strong slots conflict (person + holiday with no birthday match) → Clarify.
5. If zero slots → Show all collections **or** Unsupported `Unknown` (“Try Christmas, a person, or a place.”).
6. Confidence: High if one dictionary hit; Medium if fuzzy place/person; Low → Clarify.

Dictionary sources at runtime (already in DB):

- `EventAttributeField.holidayType` built-ins / existing `event_tags` holiday values
- `people.name` (+ `birthDate` for birthday intents)
- `locations` used by events (nickname, placeName, city)

Do not call Apple/cloud for v1 parse.

---

## Spoken layer (v1.1, same intents)

- Speech framework → text → **same** `NLIntent`.
- Spoken one-liner of `message` + result count.
- Push-to-talk on the result canvas; typed field remains.

---

## LLM layer (v2)

Model input: utterance + **catalog JSON** (holiday tag names, people names, place labels, current result summary). **No photo pixels. No GPS coordinates.**

Model output: JSON matching `NLIntent` only.

If JSON invalid or action is write without `photoIds` in context → Clarify.

---

## Failure copy (use as-is)

- Missing people: “I only know people from albums named P-something. I don’t have Faces from Photos.”
- Missing place: “I don’t have events linked to that place yet. Relink event locations, then geocode.”
- No holiday tags: “No Christmas events yet.”
- Trips: “Trip grouping isn’t filling parent trips yet, so I can’t list trips as a set. I can search a place name.”
- Video: “Magic Frame only indexes photos, not videos.”

---

## Implementation sketch (when coding starts)

1. `NLIntent` + dictionaries in `Domain/`.
2. `NLQueryParser` (pure, testable) in `Domain/` or `Services/NL/`.
3. `NLQueryBar` on `HomeView` / result screens → `LibraryViewModel.handle(intent:)`.
4. `handle` only **navigates** to filters/screens that exist; person-photo grid is the one small new surface.
5. Tests: utterance → intent fixtures (Christmas, Rachel, St George, on the frame, video).

Do not delete Home category tiles until parser hit rate is good.

---

## Out of scope until data is ready

- “All my trips” as a first-class target (needs trip containers)
- Apple Faces / “pictures of Rachel” without `P-Rachel`
- Vision lookalike queries (`christmas_tree`, `wedding`, `birthday_cake`) as default
- Video
- Cloud visual Q&A over the library
- Background voice while another app is in front
