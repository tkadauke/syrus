---
title: Operations calendar
description: See planned schedules and actual operational activity together.
---

The optional Calendar plugin adds a read-only week and agenda view of operational events. It includes your pending chat wakeups; administrators can also see recurring system maintenance and a bounded recent history of execution health. High-frequency work is condensed into cadence bands, while lower-frequency work appears on a fixed 24-hour week grid with equal hour spacing and side-by-side overlap lanes. Event height reflects actual or explicitly planned duration when available, then a source estimate, and finally a 30-minute fallback; dashed event borders identify estimates and expanded details name their provenance. The grid remains spatial on narrow screens and scrolls instead of collapsing into a list. Expand an event to compare planned and actual timestamps, duration, and health in the displayed browser timezone. Use source filters to focus the view, and follow an event link to the feature that owns it.

Calendar is an aggregation surface, not an editor. Disabling it hides the page and API without disabling scheduled work or chat wakeups. Other plugins can add authorization-aware event sources while retaining ownership of their data and actions.

When Scheduled Tasks is enabled too, Calendar shows the repository schedules
you may access. Recurring and one-shot slots use each task's configured
timezone, including daylight-saving transitions. Past slots link the planned
time to the Job and Workflow that actually ran; paused, auto-paused, fired,
skipped, and failed slots remain distinguishable. Occurrences are bounded by
the task's creation and archive times. Coworker-owned schedules are omitted
from that source because Coworkers presents them with the coworker's identity,
avatar, main-chat and schedule links, follow-up policy, and system-schedule
identity. Their occurrences distinguish work waiting for a serialized turn
from work that actually started, and correlate the resulting background
Workflow's actual start, finish, duration, and outcome. Calendar stays
optional: turning it off never pauses or otherwise changes a scheduled task.
