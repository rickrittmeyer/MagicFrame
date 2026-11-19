# MagicFrame navigation spec

Source of truth for landing-page chrome, links, and entry work.

## Files

- **`MagicFrame_Navigation_Spec.xlsx`** — open in Excel / Numbers / Google Sheets
- **`Screens.csv` / `Links.csv` / `EntryTasks.csv` / `Legend.csv`** — same data as CSV
- **`generate_navigation_spec.py`** — regenerates the workbook from the seeded “current app” map
- **`FIGMA.md`** — Figma wireframe + prototype conventions (header/body/footer/menus + nav)
- **`FigmaFrames.csv` / `FigmaPrototypeLinks.csv`** — frame checklist and prototype labels for Figma
- **`generate_figma_inventory.py`** — rebuilds the Figma CSVs from Screens/Links

## How to edit

1. Open the `.xlsx` (prefer editing sheets, not long chat prose).
2. On each row, leave **`status=current`** if it stays as-is.
3. Set **`status=change`** and edit cells for desired end-state.
4. Add new screens/links/tasks with **`status=add`**.
5. Mark obsolete rows **`status=remove`**.

For visual chrome + navigation layout, follow **`FIGMA.md`** in Figma, then say “sync nav from Figma.”

Christmas media / Events have **detailed EntryTasks** as the template for other holidays.

## Sheets

| Sheet | Meaning |
|-------|---------|
| Screens | One row per landing/major screen: header, subheader, body, footer, tab bar |
| Links | From → to navigation edges |
| EntryTasks | Ordered work when entering a screen |
| Legend | Allowed values and edit rules |

To regenerate after editing the Python seed map:

```bash
python3 docs/navigation/generate_navigation_spec.py
python3 docs/navigation/generate_figma_inventory.py
```
