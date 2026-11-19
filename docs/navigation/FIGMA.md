# MagicFrame navigation in Figma

Use Figma to lay out **header / subheader / body / footer / menus** and **navigation** in one place. The spreadsheet remains the source for EntryTasks detail.

## Files in this folder

| File | Role |
|------|------|
| [`FigmaFrames.csv`](FigmaFrames.csv) | One row per Figma frame (from `Screens.csv`) |
| [`FigmaPrototypeLinks.csv`](FigmaPrototypeLinks.csv) | Prototype connections (from `Links.csv`) |
| [`Screens.csv`](Screens.csv) / [`EntryTasks.csv`](EntryTasks.csv) | Chrome text + entry work |
| [`MagicFrame_Navigation_Spec.xlsx`](MagicFrame_Navigation_Spec.xlsx) | Same data in Excel |

## Create the Figma file

1. New Figma file: **MagicFrame Navigation**.
2. Create pages matching `figma_page` in `FigmaFrames.csv`:
   - `00 App shell`
   - `01 Media tab`
   - `02 Events tab`
   - `03 Developer tab`
   - `04 Shared`
3. Import `FigmaFrames.csv` (Plugins → “CSV Import” / copy columns) **or** create frames manually from the CSV.
4. Name every frame exactly:

   ```text
   screen_id | SwiftUIStruct
   ```

   Example: `photos.holidays.christmas.photos | HolidayTopicView`

5. Wire prototypes using `FigmaPrototypeLinks.csv` (see labels below).

Phone frame size: **390 × 844** (iPhone 14) is fine; stay consistent.

## Frame template (every screen)

Inside each frame, stack these labeled regions top → bottom:

```text
┌─────────────────────────────┐
│ Header                      │  nav title / back / trailing menus
├─────────────────────────────┤
│ Subheader                   │  icon bar, year chips, banners
├─────────────────────────────┤
│ Body                        │  grid / list / content
├─────────────────────────────┤
│ Footer                      │  selection bar (if any)
├─────────────────────────────┤
│ TabBar                      │  Media | Events | Developer
└─────────────────────────────┘
```

- Copy **Header / Subheader / Body / Footer** text from `FigmaFrames.csv` (or Screens).
- If `tab_bar=no`, omit TabBar (e.g. photo preview cover).
- Put **menu options** as a short list under Header (or a sticky note on the frame).
- Media browsers with video filter: note title variants on the Header:

  | Filter | Title pattern |
  |--------|----------------|
  | All | `{Topic} Photos and Videos` |
  | Photos | `{Topic} Photos` |
  | Videos | `{Topic} Videos` |

  Example: Christmas → `Christmas Photos and Videos` / `Christmas Photos` / `Christmas Videos`.

## Prototype link labels

Label every connection with one of:

| Label | Meaning |
|-------|---------|
| `Push` | NavigationLink / navigationDestination |
| `Sheet` | `.sheet` |
| `FullScreen` | `.fullScreenCover` |
| `Embed` | Same-stack body swap (e.g. topic → picture browser) |
| `Root` | Events/Developer filter root swap / clear focus |
| `Tab` | Custom tab bar switch into a stack root |

Control text (tile name, button) can live in the interaction description; keep the **label** as one of the six above so round-trips stay parseable.

## How to hand changes back

1. Edit frames / prototype links in Figma.
2. For structural changes, also mark the matching row in the spreadsheet (`status=change` / `add` / `remove`), **or** leave sticky notes on frames: `CHANGE: …` / `ADD: …` / `REMOVE: …`.
3. Tell me: **“sync nav from Figma”** and share the file link (or export a CSV of frame names + a screenshot/PDF of updated pages).
4. Keep `screen_id` stable in the frame name when renaming titles.

I will update Links/Screens (and code when you ask). **EntryTasks** still prefer spreadsheet edits.

## Suggested build order in Figma

1. `app.shell | MainTabView` + three tab roots (`photos.home`, `events.all`, `developer.home`).
2. Home category tiles → hubs (Holidays, Milestones, …).
3. One full holiday example (**Christmas** photos + events) including filter title variants.
4. Duplicate the Christmas pattern for other holidays (or instance a component).
5. Milestones / Outings / People / Locations / shared Event Detail + Photo Preview.

## Regenerate inventory

After regenerating the navigation workbook:

```bash
python3 docs/navigation/generate_navigation_spec.py
python3 docs/navigation/generate_figma_inventory.py
```
