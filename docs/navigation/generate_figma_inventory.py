#!/usr/bin/env python3
"""Generate FigmaFrames.csv + FigmaPrototypeLinks.csv from Screens.csv / Links.csv."""

from __future__ import annotations

import csv
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCREENS = ROOT / "Screens.csv"
LINKS = ROOT / "Links.csv"
FRAMES_OUT = ROOT / "FigmaFrames.csv"
PROTO_OUT = ROOT / "FigmaPrototypeLinks.csv"

STRUCT_BY_ID = {
    "app.shell": "MainTabView",
    "photos.home": "HomeView",
    "events.all": "EventsLibraryScreen",
    "developer.home": "DeveloperView",
    "photos.all-media": "PictureBrowserView",
    "photos.holidays": "HolidaysLandingView",
    "photos.milestones": "MilestonesLandingView",
    "photos.outings": "OutingsLandingView",
    "photos.trips": "EventsLibraryScreen",
    "photos.activities": "ActivitiesLandingView",
    "photos.vibes": "(placeholder)",
    "photos.people": "PeopleLandingView",
    "photos.people.person-photos": "PersonPhotosBrowserView",
    "photos.locations": "LocationsView",
    "photos.locations.detail": "LocationDetailView",
    "photos.archive": "ArchiveBatchesView",
    "shared.event-detail": "EventDetailView",
    "shared.photo-preview": "PhotoPreviewView",
    "photos.milestones.birthdays": "BirthdaysLandingView",
    "photos.milestones.birthdays.person-photos": "BirthdayPersonTopicView",
    "events.milestones.birthdays.person": "BirthdayPersonEventsEntryView",
    "developer.holidays.scoped": "HolidayDeveloperView",
    "developer.birthdays.scoped": "BirthdayPersonDeveloperView",
    "developer.sporting.scoped": "SportingEventsDeveloperView",
}


def infer_struct(screen_id: str, body: str) -> str:
    if screen_id in STRUCT_BY_ID:
        return STRUCT_BY_ID[screen_id]
    if ".holidays." in screen_id and screen_id.endswith(".photos"):
        return "HolidayTopicView"
    if screen_id.startswith("events.holidays."):
        return "HolidayEventsEntryView"
    if ".milestones." in screen_id and screen_id.endswith(".photos"):
        return "MilestoneTopicView"
    if screen_id.startswith("events.milestones."):
        return "MilestoneEventsEntryView"
    if ".outings." in screen_id and screen_id.endswith(".photos"):
        return "OutingTopicView"
    if screen_id.startswith("events.outings."):
        return "OutingEventsEntryView"
    if screen_id.startswith("photos.activities."):
        return "EventsLibraryScreen"
    match = re.search(r"\b([A-Z][A-Za-z0-9]+(?:View|Screen))\b", body)
    if match:
        return match.group(1)
    return "TODO"


def page_for(tab: str, screen_id: str) -> str:
    if screen_id == "app.shell":
        return "00 App shell"
    if screen_id.startswith("shared."):
        return "04 Shared"
    if tab == "Media" or screen_id.startswith("photos."):
        return "01 Media tab"
    if tab == "Events" or screen_id.startswith("events."):
        return "02 Events tab"
    if tab == "Developer" or screen_id.startswith("developer."):
        return "03 Developer tab"
    return "99 Other"


def effect_to_proto(effect: str) -> str:
    lower = effect.lower()
    if "tab_switch" in lower:
        return "Tab"
    if "fullscreen" in lower or "full_screen" in lower:
        return "FullScreen"
    if "sheet" in lower:
        return "Sheet"
    if "embed" in lower:
        return "Embed"
    if "eventstabfilter" in effect or "mirror" in lower or "clear" in lower:
        return "Root"
    if "push" in lower:
        return "Push"
    return "Push"


def main() -> None:
    frames = []
    with SCREENS.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            struct = infer_struct(row["screen_id"], row["body"])
            frames.append(
                {
                    "frame_name": f"{row['screen_id']} | {struct}",
                    "screen_id": row["screen_id"],
                    "swiftui_struct": struct,
                    "figma_page": page_for(row["tab"], row["screen_id"]),
                    "title": row["title"],
                    "tab": row["tab"],
                    "header": row["header"],
                    "subheader": row["subheader"],
                    "body": row["body"],
                    "footer": row["footer"],
                    "tab_bar": "yes" if row["tab_bar"].startswith("visible") else "no",
                    "status": row["status"],
                    "notes": row.get("notes", ""),
                }
            )

    frame_fields = [
        "frame_name",
        "screen_id",
        "swiftui_struct",
        "figma_page",
        "title",
        "tab",
        "header",
        "subheader",
        "body",
        "footer",
        "tab_bar",
        "status",
        "notes",
    ]
    with FRAMES_OUT.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=frame_fields)
        writer.writeheader()
        writer.writerows(frames)

    proto = []
    with LINKS.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            proto.append(
                {
                    "from_screen_id": row["from_id"],
                    "to_screen_id": row["to_id"],
                    "control": row["control"],
                    "prototype_label": effect_to_proto(row["effect"]),
                    "effect": row["effect"],
                    "status": row["status"],
                }
            )

    with PROTO_OUT.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "from_screen_id",
                "to_screen_id",
                "control",
                "prototype_label",
                "effect",
                "status",
            ],
        )
        writer.writeheader()
        writer.writerows(proto)

    print(f"Wrote {FRAMES_OUT} ({len(frames)} frames)")
    print(f"Wrote {PROTO_OUT} ({len(proto)} links)")


if __name__ == "__main__":
    main()
