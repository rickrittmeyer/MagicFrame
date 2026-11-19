#!/usr/bin/env python3
"""Generate MagicFrame navigation spec workbook + CSVs from current app structure."""

from __future__ import annotations

import csv
from pathlib import Path

from openpyxl import Workbook
from openpyxl.styles import Font, Alignment, PatternFill
from openpyxl.utils import get_column_letter

OUT_DIR = Path(__file__).resolve().parent

HOLIDAYS = [
    "Christmas",
    "Halloween",
    "Thanksgiving",
    "Easter",
    "July 4th",
    "New Years",
    "Valentine's Day",
    "St. Patty's Day",
    "Mother's Day",
    "Father's Day",
]

MILESTONES = [
    ("birthdays", "Birthdays", "Birthdays landing → person tiles (special)"),
    ("weddings", "Weddings", "Milestone topic → Photos + Events mirror"),
    ("graduations", "Graduations", "Milestone topic → Photos + Events mirror"),
    ("proms", "Proms", "Milestone topic → Photos + Events mirror"),
    ("christening", "Christening", "Milestone topic → Photos + Events mirror"),
    ("baptism", "Baptism", "Milestone topic → Photos + Events mirror"),
    ("celebration-of-life", "Celebration of Life", "Milestone topic → Photos + Events mirror"),
]

OUTINGS = [
    ("sporting-events", "Sporting Events"),
    ("plays", "Plays"),
    ("concerts", "Concerts"),
]

ACTIVITIES = ["Dance", "Hiking", "Cornhole"]

SCREEN_HEADERS = [
    "screen_id",
    "title",
    "tab",
    "parent_id",
    "how_opened",
    "header",
    "subheader",
    "body",
    "footer",
    "tab_bar",
    "notes",
    "status",
]

LINK_HEADERS = [
    "from_id",
    "to_id",
    "control",
    "effect",
    "status",
]

TASK_HEADERS = [
    "screen_id",
    "step",
    "when",
    "task",
    "details",
    "blocks_ui",
    "status",
]

LEGEND_ROWS = [
    ["column", "allowed_values", "notes"],
    ["tab", "Media | Events | Developer | Search", "Which tab owns the screen"],
    ["how_opened", "tab_root | NavigationLink | eventsTabFilter_mirror | fullScreenCover | sheet", ""],
    ["when", "always | if_not_done | if_stale | on_year_expand | on_disappear", "EntryTasks.when"],
    ["blocks_ui", "spinner | show_stale | background | none", "EntryTasks.blocks_ui"],
    ["status", "current | keep | change | add | remove", "Edit status for planning; start from current"],
    ["screen_id", "photos.* | events.* | developer.* | shared.*", "Dot path; keep stable when renaming titles"],
    ["tab_bar", "full (Media|Events|Developer|Search) | landing (Help|Developer)", "Landing hubs vs topic/full tabs"],
    ["", "", ""],
    ["HOW_TO_EDIT", "", "Leave status=current if unchanged. Set change and edit cells. Add rows with status=add. Mark obsolete remove."],
    ["HANDOFF", "", "Edit this workbook (or CSV exports). Prefer sheet edits over long prose. Deltas can be notes in status=change rows."],
]


def slug(s: str) -> str:
    return (
        s.lower()
        .replace("'", "")
        .replace(".", "")
        .replace(" ", "-")
        .replace("/", "-")
    )


def screen(
    screen_id: str,
    title: str,
    tab: str,
    parent_id: str,
    how_opened: str,
    header: str,
    subheader: str,
    body: str,
    footer: str,
    tab_bar: str = "full (Media|Events|Developer|Search)",
    notes: str = "",
    status: str = "current",
) -> list:
    return [
        screen_id,
        title,
        tab,
        parent_id,
        how_opened,
        header,
        subheader,
        body,
        footer,
        tab_bar,
        notes,
        status,
    ]


def link(from_id: str, to_id: str, control: str, effect: str, status: str = "current") -> list:
    return [from_id, to_id, control, effect, status]


def task(
    screen_id: str,
    step: int,
    when: str,
    task_name: str,
    details: str,
    blocks_ui: str,
    status: str = "current",
) -> list:
    return [screen_id, step, when, task_name, details, blocks_ui, status]


def build_screens() -> list[list]:
    rows: list[list] = [SCREEN_HEADERS]

    # App / tabs
    rows.append(
        screen(
            "app.shell",
            "App Shell",
            "Media",
            "",
            "app_launch",
            "—",
            "—",
            "MainTabView (landing Help|Developer vs full Media|Events|Developer|Search; Search placeholder)",
            "—",
            "full (Media|Events|Developer|Search)",
            "ContentView hosts MainTabView; onboarding fullScreenCover",
        )
    )
    rows.append(
        screen(
            "photos.home",
            "Home",
            "Media",
            "tab.root",
            "tab_root",
            "Inline title: Home; Magic Frame brand header",
            "Optional background-work banner",
            "HomeCategoryGridView (All Media, Holidays, Milestones, Outings, Trips, Activities, Vibes placeholder, People, Locations); Archive link if needed",
            "—",
            "landing (Help|Developer)",
            notes="onAppear clears eventsTabFilter",
        )
    )
    rows.append(
        screen(
            "events.all",
            "All Events",
            "Events",
            "tab.root",
            "tab_root",
            "Inline title: All Events (no back)",
            "Icon bar (count, sort Date|Confidence, filter, select); year jump bar",
            "EventsLibraryView month sections (sticky headers) → EventDetailView",
            "Selection: Favorite|Unfavorite|Hide|Unhide|Merge soon; ADD AI Analysis + Delete (status=change)",
            notes="Default Events tab when eventsTabFilter=.allEvents; deferred mount after tab paint",
        )
    )
    rows.append(
        screen(
            "developer.home",
            "Developer",
            "Developer",
            "tab.root",
            "tab_root",
            "Inline title: Developer; status caption",
            "—",
            "Grouped list: index/sync, vision, face, holiday vision, browse links",
            "—",
        )
    )

    rows.append(
        screen(
            "search.home",
            "Search",
            "Search",
            "tab.root",
            "tab_root",
            "Inline title: Search",
            "—",
            "SearchPlaceholderView — pictures + events coming soon",
            "—",
            notes="Placeholder tab from Figma sync",
        )
    )
    rows.append(
        screen(
            "shared.help",
            "Help",
            "Media",
            "app.shell",
            "sheet",
            "Inline title: Help",
            "—",
            "HelpPlaceholderView — coming soon",
            "—",
            "landing (Help|Developer)",
            notes="Opened from landing chrome Help button",
        )
    )

    # Photos hubs
    rows.append(
        screen(
            "photos.all-media",
            "All Photos and Videos",
            "Media",
            "photos.home",
            "NavigationLink",
            "Inline title: All Photos and Videos | All Photos | All Videos by filter",
            "Icon bar (count, sort dateTaken/dateImported, photo/video filter, select); year jump bar",
            "PictureBrowserView full-library grid → PhotoPreviewView",
            "Selection bar when selecting; ADD Share (status=change)",
            notes="Figma: select Footer Share=change; chrome full Media|Events|Developer|Search",
            status="current",
        )
    )
    rows.append(
        screen(
            "photos.holidays",
            "Holidays",
            "Media",
            "photos.home",
            "NavigationLink",
            "Large title: Holidays",
            "—",
            "Grid of HolidayLandingCard (catalog holidays + birthday-person cards by next occurrence)",
            "—",
            "landing (Help|Developer)",
            notes="onAppear clearEventsTabFocus; refreshes holiday landing catalog",
        )
    )
    rows.append(
        screen(
            "photos.milestones",
            "Milestones",
            "Media",
            "photos.home",
            "NavigationLink",
            "Large title: Milestones",
            "—",
            "Grid: Birthdays, Weddings, Graduations, Proms, Christening, Baptism, Celebration of Life",
            "—",
            "landing (Help|Developer)",
        )
    )
    rows.append(
        screen(
            "photos.outings",
            "Outings",
            "Media",
            "photos.home",
            "NavigationLink",
            "Large title: Outings",
            "—",
            "Grid: Sporting Events, Plays, Concerts",
            "—",
            "landing (Help|Developer)",
        )
    )
    rows.append(
        screen(
            "photos.trips",
            "Trips Events",
            "Media",
            "photos.home",
            "NavigationLink",
            "Inline title: Trips Events",
            "Event list icon bar + year jump (picture-style chrome)",
            "EventsLibraryScreen filter=.trips",
            "Selection bar when selecting",
        )
    )
    rows.append(
        screen(
            "photos.activities",
            "Activities",
            "Media",
            "photos.home",
            "NavigationLink",
            "Large title: Activities",
            "—",
            "Tiles: Dance, Hiking, Cornhole → each opens activity-filtered event list",
            "—",
            "landing (Help|Developer)",
        )
    )
    rows.append(
        screen(
            "photos.vibes",
            "Vibes",
            "Media",
            "photos.home",
            "placeholder",
            "—",
            "—",
            "Coming soon (disabled card)",
            "—",
            "landing (Help|Developer)",
            notes="Not navigable yet",
        )
    )
    rows.append(
        screen(
            "photos.people",
            "People",
            "Media",
            "photos.home",
            "NavigationLink",
            "Large title: People",
            "Face scan progress / Rebuild clusters / reset",
            "Named people list; unnamed cluster grid; naming/merge sheets",
            "—",
            "landing (Help|Developer)",
        )
    )
    rows.append(
        screen(
            "photos.people.person-photos",
            "Person Photos",
            "Media",
            "photos.people",
            "NavigationLink",
            "Inline person display name",
            "Picture browser chrome (icon bar; year jump if applicable)",
            "PictureBrowserView of face-linked photo IDs",
            "—",
            notes="Does not set eventsTabFilter",
        )
    )
    rows.append(
        screen(
            "photos.locations",
            "Locations",
            "Media",
            "photos.home",
            "NavigationLink",
            "Inline title: Locations; searchable; trailing status",
            "—",
            "Locations list",
            "—",
            "landing (Help|Developer)",
        )
    )
    rows.append(
        screen(
            "photos.locations.detail",
            "Location Detail",
            "Media",
            "photos.locations",
            "NavigationLink",
            "Inline location title; map/nickname/home flags header",
            "Compact hidden-events toggle (no picture-style icon bar)",
            "Embedded EventsLibraryListContent for that location",
            "—",
        )
    )
    rows.append(
        screen(
            "photos.archive",
            "Archive",
            "Media",
            "photos.home",
            "NavigationLink",
            "Archive batches UI",
            "—",
            "ArchiveBatchesView",
            "—",
            notes="Only if archivePhotoCount > 0",
        )
    )

    # Shared leafs
    rows.append(
        screen(
            "shared.event-detail",
            "Event Detail",
            "Media",
            "(any event list)",
            "NavigationLink",
            "Event title / edit chrome",
            "—",
            "Event photos, tags, people, scoring UI",
            "—",
            notes="Also reachable from Events tab lists",
        )
    )
    rows.append(
        screen(
            "shared.photo-preview",
            "Photo Preview",
            "Media",
            "(any picture browser)",
            "fullScreenCover",
            "Overlay chrome (frame/hide/favorite; face name overlays)",
            "—",
            "Swipeable fullscreen photos",
            "—",
            tab_bar="hidden (cover)",
        )
    )

    # Holidays — pattern + each
    for name in HOLIDAYS:
        sid = slug(name)
        photos_id = f"photos.holidays.{sid}.photos"
        events_id = f"events.holidays.{sid}"
        topic_notes = (
            "EXAMPLE ROW — fill desired end-state in status=change"
            if name == "Christmas"
            else "Same pattern as Christmas media browser; edit if this holiday differs"
        )
        rows.append(
            screen(
                photos_id,
                f"{name} Photos and Videos",
                "Media",
                "photos.holidays",
                "NavigationLink",
                f"Inline title: {name} Photos and Videos | Photos | Videos by filter (PictureBrowserView)",
                "Icon bar + year jump (picture browser)",
                f"HolidayTopicView → Picture Search results for {name}",
                "—",
                notes=topic_notes
                + f"; onAppear focusEventsTabOnHoliday('{name}')",
            )
        )
        rows.append(
            screen(
                events_id,
                f"{name} Events",
                "Events",
                "tab.root",
                "eventsTabFilter_mirror",
                f"Inline title: {name} Events; EventsTabBackButton → Media Holidays hub",
                "Event list icon bar + year jump; year expand may run holiday Vision",
                f"HolidayEventsEntryView → EventsLibraryListContent landingTitle='{name} Events'",
                "Selection bar when selecting",
                notes="Shown when Media topic set eventsTabFilter and user taps Events tab"
                + ("; DETAILED ENTRY TASKS below" if name == "Christmas" else ""),
            )
        )

    # Milestones
    rows.append(
        screen(
            "photos.milestones.birthdays",
            "Birthdays",
            "Media",
            "photos.milestones",
            "NavigationLink",
            "Large title: Birthdays",
            "—",
            "Per-person tiles (people with birth dates)",
            "—",
            "landing (Help|Developer)",
        )
    )
    rows.append(
        screen(
            "photos.milestones.birthdays.person-photos",
            "{Person} Birthday Photos and Videos",
            "Media",
            "photos.milestones.birthdays",
            "NavigationLink",
            "Inline: {Name} Birthday Photos and Videos | Photos | Videos by filter",
            "Picture browser chrome",
            "BirthdayPersonTopicView → PictureBrowserView",
            "—",
            notes="Also reachable from Holidays grid birthday cards; sets eventsTabFilter to birthday person",
        )
    )
    rows.append(
        screen(
            "events.milestones.birthdays.person",
            "{Person} Birthday Events",
            "Events",
            "tab.root",
            "eventsTabFilter_mirror",
            "Inline title; EventsTabBackButton",
            "Event list chrome",
            "BirthdayPersonEventsEntryView scored list",
            "—",
        )
    )

    for mid, title, note in MILESTONES:
        if mid == "birthdays":
            continue
        rows.append(
            screen(
                f"photos.milestones.{mid}.photos",
                f"{title} Photos and Videos",
                "Media",
                "photos.milestones",
                "NavigationLink",
                f"Inline: {title} Photos and Videos | Photos | Videos by filter",
                "Picture browser chrome",
                f"MilestoneTopicView({mid}) → Picture Search results",
                "—",
                notes=note + "; onAppear focusEventsTabOnMilestone",
            )
        )
        rows.append(
            screen(
                f"events.milestones.{mid}",
                f"{title} Events",
                "Events",
                "tab.root",
                "eventsTabFilter_mirror",
                f"Inline: {title} Events; back clears focus",
                "Event list chrome",
                "MilestoneEventsEntryView → filtered/scored event list",
                "—",
            )
        )

    # Outings
    for oid, title in OUTINGS:
        rows.append(
            screen(
                f"photos.outings.{oid}.photos",
                f"{title} Photos and Videos",
                "Media",
                "photos.outings",
                "NavigationLink",
                f"Inline: {title} Photos and Videos | Photos | Videos by filter",
                "Picture browser chrome",
                f"OutingTopicView({oid}) → Picture Search results",
                "—",
                notes="onAppear focusEventsTabOnOuting",
            )
        )
        rows.append(
            screen(
                f"events.outings.{oid}",
                f"{title} Events",
                "Events",
                "tab.root",
                "eventsTabFilter_mirror",
                f"Inline: {title} Events; back clears focus",
                "Event list chrome (sport/team sort for sporting)",
                "OutingEventsEntryView → filtered/scored event list",
                "—",
            )
        )

    # Activities → event lists on Photos stack
    for act in ACTIVITIES:
        sid = slug(act)
        rows.append(
            screen(
                f"photos.activities.{sid}",
                f"{act} Events",
                "Media",
                "photos.activities",
                "NavigationLink",
                f"Inline: {act} Events",
                "Event list chrome",
                f"EventsLibraryScreen filter=.activityTag({act})",
                "—",
            )
        )

    # Developer focused roots
    rows.append(
        screen(
            "developer.holidays.scoped",
            "Holiday Developer (scoped)",
            "Developer",
            "tab.root",
            "eventsTabFilter_mirror",
            "Inline holiday tagValue",
            "—",
            "HolidayDeveloperView: Picture Search, scorer, link to HolidayEventsEntryView",
            "—",
            notes="When eventsTabFilter is a holiday tag",
        )
    )
    rows.append(
        screen(
            "developer.birthdays.scoped",
            "Birthday Person Developer",
            "Developer",
            "tab.root",
            "eventsTabFilter_mirror",
            "Inline displayName",
            "—",
            "BirthdayPersonDeveloperView",
            "—",
        )
    )
    rows.append(
        screen(
            "developer.sporting.scoped",
            "Sporting Events Developer",
            "Developer",
            "tab.root",
            "eventsTabFilter_mirror",
            "Inline Sporting Events",
            "—",
            "SportingEventsDeveloperView stadium catalog",
            "—",
        )
    )

    return rows


def build_links() -> list[list]:
    rows: list[list] = [LINK_HEADERS]

    # Home tiles
    home_links = [
        ("photos.all-media", "All Media tile", "push"),
        ("photos.holidays", "Holidays tile", "push"),
        ("photos.milestones", "Milestones tile", "push"),
        ("photos.outings", "Outings tile", "push"),
        ("photos.trips", "Trips tile", "push"),
        ("photos.activities", "Activities tile", "push"),
        ("photos.people", "People tile", "push"),
        ("photos.locations", "Locations tile", "push"),
        ("photos.archive", "Archive link", "push"),
    ]
    for to_id, control, effect in home_links:
        rows.append(link("photos.home", to_id, control, effect))

    rows.append(link("tab.photos", "photos.home", "Media tab", "tab_switch"))
    rows.append(link("tab.search", "search.home", "Search tab", "tab_switch"))
    rows.append(link("landing.help", "shared.help", "Help (landing chrome)", "sheet"))
    rows.append(link("landing.developer", "developer.home", "Developer (landing chrome)", "tab_switch"))
    rows.append(link("tab.events", "events.all", "Events tab (default filter)", "tab_switch"))
    rows.append(
        link(
            "tab.events",
            "events.holidays.*",
            "Events tab when eventsTabFilter set",
            "tab_switch + mirror root",
        )
    )
    rows.append(link("tab.developer", "developer.home", "Developer tab", "tab_switch"))

    for name in HOLIDAYS:
        sid = slug(name)
        rows.append(
            link(
                "photos.holidays",
                f"photos.holidays.{sid}.photos",
                f"{name} card",
                "push",
            )
        )
        rows.append(
            link(
                f"photos.holidays.{sid}.photos",
                f"events.holidays.{sid}",
                "onAppear sets eventsTabFilter",
                "set eventsTabFilter (user must tap Events tab)",
            )
        )
        rows.append(
            link(
                f"events.holidays.{sid}",
                "photos.holidays",
                "EventsTabBackButton",
                "root_to_media_holidays",
            )
        )

    rows.append(link("photos.milestones", "photos.milestones.birthdays", "Birthdays tile", "push"))
    rows.append(
        link(
            "photos.milestones.birthdays",
            "photos.milestones.birthdays.person-photos",
            "Person tile",
            "push",
        )
    )
    rows.append(
        link(
            "photos.milestones.birthdays.person-photos",
            "events.milestones.birthdays.person",
            "onAppear focusEventsTabOnMilestone(birthdayPerson)",
            "set eventsTabFilter",
        )
    )

    for mid, title, _ in MILESTONES:
        if mid == "birthdays":
            continue
        rows.append(
            link(
                "photos.milestones",
                f"photos.milestones.{mid}.photos",
                f"{title} tile",
                "push",
            )
        )
        rows.append(
            link(
                f"photos.milestones.{mid}.photos",
                f"events.milestones.{mid}",
                "onAppear focusEventsTabOnMilestone",
                "set eventsTabFilter",
            )
        )

    for oid, title in OUTINGS:
        rows.append(link("photos.outings", f"photos.outings.{oid}.photos", f"{title} tile", "push"))
        rows.append(
            link(
                f"photos.outings.{oid}.photos",
                f"events.outings.{oid}",
                "onAppear focusEventsTabOnOuting",
                "set eventsTabFilter",
            )
        )

    for act in ACTIVITIES:
        rows.append(
            link(
                "photos.activities",
                f"photos.activities.{slug(act)}",
                f"{act} tile",
                "push",
            )
        )

    rows.append(link("photos.people", "photos.people.person-photos", "Named person row", "push"))
    rows.append(link("photos.locations", "photos.locations.detail", "Location row", "push"))
    rows.append(
        link(
            "(any event list)",
            "shared.event-detail",
            "Event row",
            "push",
        )
    )
    rows.append(
        link(
            "(any picture browser)",
            "shared.photo-preview",
            "Photo cell",
            "fullScreenCover",
        )
    )
    rows.append(
        link(
            "photos.home",
            "events.all",
            "Home onAppear",
            "clearEventsTabFocus (does not switch tab)",
        )
    )

    return rows


def build_tasks() -> list[list]:
    rows: list[list] = [TASK_HEADERS]

    # App
    rows.append(
        task(
            "app.shell",
            1,
            "always",
            "startup_pipeline",
            "vm.onAppear(); visionJobCoordinator.startIfNeeded()",
            "background",
        )
    )
    rows.append(
        task(
            "app.shell",
            2,
            "if_not_done",
            "load_events_for_ui",
            "After isStartupComplete: loadEventsForUIIfNeeded()",
            "background",
        )
    )

    # Home
    rows.append(
        task(
            "photos.home",
            1,
            "always",
            "clear_events_tab_focus",
            "clearEventsTabFocus()",
            "none",
        )
    )
    rows.append(
        task(
            "photos.home",
            2,
            "always",
            "refresh_home_counts",
            "refreshHomeCategoryCounts()",
            "background",
        )
    )

    # All Media
    rows.append(
        task(
            "photos.all-media",
            1,
            "always",
            "load_picture_browser",
            "PictureBrowserViewModel.load() for full library",
            "spinner",
        )
    )

    # Holidays hub
    rows.append(
        task(
            "photos.holidays",
            1,
            "always",
            "clear_events_tab_focus",
            "onAppear clearEventsTabFocus()",
            "none",
        )
    )
    rows.append(
        task(
            "photos.holidays",
            2,
            "always",
            "refresh_holiday_landing",
            "scheduleHolidayLandingRefresh() → DB holiday catalog + birthday cards",
            "background",
        )
    )
    rows.append(
        task(
            "photos.holidays",
            3,
            "on_disappear",
            "cancel_holiday_landing_refresh",
            "cancel scheduled refresh",
            "none",
        )
    )

    # Christmas Photos — detailed example (current behavior)
    xmas_photos = "photos.holidays.christmas.photos"
    rows.append(
        task(
            xmas_photos,
            1,
            "always",
            "focus_events_tab_filter",
            "onAppear: focusEventsTabOnHoliday('Christmas') so Events tab mirrors Christmas Events",
            "none",
        )
    )
    rows.append(
        task(
            xmas_photos,
            2,
            "if_not_done",
            "vision_prep_holiday_tags",
            "prepareHolidayVisionTagsIfNeeded for Christmas date window / vision tag criteria (idempotent if already tagged)",
            "spinner",
        )
    )
    rows.append(
        task(
            xmas_photos,
            3,
            "always",
            "run_holiday_picture_search",
            "runHolidayPictureSearch('Christmas'); may enqueue face detect if performFaceDetect on definition",
            "spinner",
        )
    )
    rows.append(
        task(
            xmas_photos,
            4,
            "always",
            "display_picture_browser",
            "Show PictureBrowserView; title Christmas Photos and Videos / Christmas Photos / Christmas Videos by filter; select Footer ADD Share (status=change)",
            "none",
        )
    )

    # Christmas Events — detailed example
    xmas_events = "events.holidays.christmas"
    rows.append(
        task(
            xmas_events,
            1,
            "always",
            "begin_event_list_load",
            "beginEventListLoad(.holidayTag Christmas); sets activeHolidayVisionConfig",
            "spinner",
        )
    )
    rows.append(
        task(
            xmas_events,
            2,
            "if_not_done",
            "vision_prep_holiday_tags",
            "Same vision prep as photos path if tags needed",
            "spinner",
        )
    )
    rows.append(
        task(
            xmas_events,
            3,
            "if_stale",
            "reuse_or_run_picture_search",
            "Reuse latest Picture Search run if non-empty; else runHolidayPictureSearch",
            "spinner",
        )
    )
    rows.append(
        task(
            xmas_events,
            4,
            "always",
            "score_candidate_events",
            "Score candidate events from picture matches (event type check / score card)",
            "spinner",
        )
    )
    rows.append(
        task(
            xmas_events,
            5,
            "always",
            "reload_events_list",
            "reloadEventsAsync for Christmas-filtered events; enrich slideshow/game after paint",
            "spinner",
        )
    )
    rows.append(
        task(
            xmas_events,
            6,
            "on_year_expand",
            "holiday_year_object_recognition",
            "handleHolidayYearExpanded → enqueueHolidayYearObjectRecognitionJobs for landing Vision",
            "background",
        )
    )
    rows.append(
        task(
            xmas_events,
            7,
            "on_disappear",
            "cancel_holiday_landing_vision",
            "cancelHolidayLandingVisionScans if active",
            "none",
        )
    )

    # Generic note for other holidays
    rows.append(
        task(
            "photos.holidays.{holiday}.photos",
            1,
            "always",
            "same_as_christmas_photos_pattern",
            "Copy Christmas Photos EntryTasks; substitute holiday name. Mark status=change if a holiday differs.",
            "spinner",
            "current",
        )
    )
    rows.append(
        task(
            "events.holidays.{holiday}",
            1,
            "always",
            "same_as_christmas_events_pattern",
            "Copy Christmas Events EntryTasks; substitute holiday name.",
            "spinner",
            "current",
        )
    )

    # All Events
    rows.append(
        task(
            "events.all",
            1,
            "always",
            "begin_event_list_load",
            "beginEventListLoad(.allEvents) — no 450ms push delay",
            "spinner",
        )
    )
    rows.append(
        task(
            "events.all",
            2,
            "always",
            "reload_events_async",
            "reloadEventsAsync(loadSlideshowIds: true); chunked slideshow enrichment after paint",
            "spinner",
        )
    )
    rows.append(
        task(
            "events.all",
            3,
            "always",
            "schedule_event_date_repair",
            "scheduleEventDateRepairIfNeeded() (All Events only)",
            "background",
        )
    )

    # Milestone / outing patterns
    rows.append(
        task(
            "photos.milestones.{topic}.photos",
            1,
            "always",
            "run_milestone_photos_pipeline",
            "Vision prep if needed → Picture Search; focusEventsTabOnMilestone",
            "spinner",
        )
    )
    rows.append(
        task(
            "events.milestones.{topic}",
            1,
            "always",
            "run_milestone_events_pipeline",
            "Reuse/search → score → beginEventListLoad + reloadEventsAsync",
            "spinner",
        )
    )
    rows.append(
        task(
            "photos.outings.{topic}.photos",
            1,
            "always",
            "run_outing_photos_pipeline",
            "Vision prep if needed → Picture Search; focusEventsTabOnOuting",
            "spinner",
        )
    )
    rows.append(
        task(
            "events.outings.{topic}",
            1,
            "always",
            "run_outing_events_pipeline",
            "Reuse/search → score → beginEventListLoad + reloadEventsAsync",
            "spinner",
        )
    )

    # People
    rows.append(
        task(
            "photos.people",
            1,
            "always",
            "face_progress_and_clusters",
            "Repair face progress if needed; refresh people + unnamed clusters; optional auto-rebuild",
            "spinner",
        )
    )
    rows.append(
        task(
            "photos.people.person-photos",
            1,
            "always",
            "fetch_person_photo_ids",
            "fetchPhotoIdsForPerson → PictureBrowserView",
            "spinner",
        )
    )

    # Locations
    rows.append(
        task(
            "photos.locations",
            1,
            "always",
            "locations_on_appear",
            "LocationsViewModel.onAppear()",
            "background",
        )
    )
    rows.append(
        task(
            "photos.locations.detail",
            1,
            "always",
            "load_location_and_events",
            "Load location; EventsLibraryListContent.task reload for location filter",
            "spinner",
        )
    )

    # Hubs refresh
    rows.append(
        task(
            "photos.milestones",
            1,
            "always",
            "refresh_milestone_landing_items",
            "refreshMilestoneLandingItems(); clearEventsTabFocus on appear",
            "background",
        )
    )
    rows.append(
        task(
            "photos.outings",
            1,
            "always",
            "refresh_outing_landing_items",
            "refreshOutingLandingItems(); clearEventsTabFocus on appear",
            "background",
        )
    )
    rows.append(
        task(
            "photos.activities",
            1,
            "always",
            "refresh_activity_landing_items",
            "refreshActivityLandingItems()",
            "background",
        )
    )

    return rows


def autosize(ws) -> None:
    for col in range(1, ws.max_column + 1):
        letter = get_column_letter(col)
        max_len = 0
        for cell in ws[letter]:
            if cell.value is None:
                continue
            max_len = max(max_len, min(len(str(cell.value)), 60))
        ws.column_dimensions[letter].width = max(12, max_len + 2)


def style_header(ws) -> None:
    fill = PatternFill("solid", fgColor="1F4E79")
    font = Font(color="FFFFFF", bold=True)
    for cell in ws[1]:
        cell.fill = fill
        cell.font = font
        cell.alignment = Alignment(wrap_text=True, vertical="top")
    ws.freeze_panes = "A2"
    for row in ws.iter_rows(min_row=2):
        for cell in row:
            cell.alignment = Alignment(wrap_text=True, vertical="top")


def write_csv(name: str, rows: list[list]) -> Path:
    path = OUT_DIR / name
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerows(rows)
    return path


def main() -> None:
    screens = build_screens()
    links = build_links()
    tasks = build_tasks()
    legend = LEGEND_ROWS

    write_csv("Screens.csv", screens)
    write_csv("Links.csv", links)
    write_csv("EntryTasks.csv", tasks)
    write_csv("Legend.csv", legend)

    wb = Workbook()
    ws_s = wb.active
    ws_s.title = "Screens"
    for row in screens:
        ws_s.append(row)
    style_header(ws_s)
    autosize(ws_s)

    ws_l = wb.create_sheet("Links")
    for row in links:
        ws_l.append(row)
    style_header(ws_l)
    autosize(ws_l)

    ws_t = wb.create_sheet("EntryTasks")
    for row in tasks:
        ws_t.append(row)
    style_header(ws_t)
    autosize(ws_t)

    ws_g = wb.create_sheet("Legend")
    for row in legend:
        ws_g.append(row)
    style_header(ws_g)
    autosize(ws_g)

    xlsx_path = OUT_DIR / "MagicFrame_Navigation_Spec.xlsx"
    wb.save(xlsx_path)
    print(f"Wrote {xlsx_path}")
    print(f"Screens: {len(screens) - 1} rows")
    print(f"Links: {len(links) - 1} rows")
    print(f"EntryTasks: {len(tasks) - 1} rows")


if __name__ == "__main__":
    main()
