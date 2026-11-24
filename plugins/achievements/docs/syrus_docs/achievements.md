# Achievements

The `achievements` plugin owns achievement definitions, canonical unlocks, and
per-user acknowledgments. It is disabled by default, experimental, and can be
toggled in **Admin → Plugins**. The bundled definitions are neutral `example.*`
fixtures rather than a launch catalog.

## Definitions

Each definition has a stable `key` (lowercase dotted snake_case), a positive
integer `version`, and:

| Field | Meaning |
|---|---|
| `scope` | `instance` (a milestone unlocked once per installation) or `user` (an accomplishment attributed to one user) |
| `trigger` / `evaluator` | Identities of the domain event and evaluator class that will award it |
| `subject_kinds` | What the unlock may point at: `job`, `epic`, `repository`, `workflow`, `user`, `installation` |
| `visibility` | `visible` or `hidden` |
| `category`, `rarity` | Closed vocabularies for grouping and presentation tiers |
| `presentation` | Fixture metadata only: `title_key`, `description_key`, `glyph`, `teaser_key` (strings up to 200 characters) |

The registry validates the whole set: duplicate keys, unknown vocabulary,
empty or duplicate subject kinds, `instance` scope with a `user` subject,
`user` scope with an `installation` subject, unknown or oversized presentation
values, and a `teaser_key` on a hidden definition. Problems are logged at boot
and never stop the instance; code that must refuse to proceed uses
`Achievements::Registry#validate!`.

## Unlocks and acknowledgments

An unlock is unique per definition and owner (`instance`, or `user:<id>`), so
repeated delivery of the same event is idempotent and keeps the first unlock's
evidence. The subject (a Job or Epic) is recorded for linking, but does not
change uniqueness. Evidence is bounded primitive JSON: string-keyed hashes,
arrays, strings, numbers, booleans and nulls, nested at most three levels,
strings up to 500 characters, 4 KiB total.

Acknowledgment is per user and unique per unlock, including for instance
unlocks; acknowledging never changes the unlock. Only the attributed user can
acknowledge a user unlock.

## Disabling, retention, and purge

- **Disable** keeps all rows. Cleanup below still runs while disabled.
- Destroying a **user** removes the unlocks attributed to them and the
  acknowledgments they recorded. Instance unlocks remain.
- A **Job or Epic** subject is a weak reference: destroying it keeps the unlock
  and its evidence, and readers must tolerate a subject that no longer resolves.
- Unlocks are history and are never aged out.
- **Purge** (`bin/rails 'plugin:purge[achievements]'`) drops the two
  `achievements_*` tables. The plugin holds no data outside the database, and
  adds no columns or callbacks to core tables.

## Evaluation

The plugin subscribes to domain events (`job.closed`, `epic.upserted`) and never
adds callbacks to core models. Each event is matched to the definitions whose
`trigger` names it and handed to the definition's evaluator. Delivery is
at-least-once and unordered, so evaluation only ever calls the idempotent unlock
write: repeated or reordered events cannot duplicate an unlock, and the first
unlock's timestamp and evidence are kept.

Invalid definitions are logged and skipped; a transient failure such as a database error is handed to a plugin-owned background job that retries with backoff, so the event is not lost (core never retries failed domain-event subscribers itself).

**Attribution.** An instance milestone is never credited to a person. A per-user
accomplishment is credited only for work an operator started themselves: a
`direct` Job created by core, or an Epic created by an operator. Scheduled
fires, ingested issues, coworker and insight work, infrastructure Jobs, and
anyone who merely closed, merged, or reviewed a Job earn nothing for a user.
When nobody can be credited, a per-user definition is not awarded.

## Acknowledgments and reveals

Everyone sees every instance unlock; a user sees only their own user unlocks.
Another user's unlock behaves as if it does not exist. The API (all under
`/api/v1/app`) returns definition metadata and unlock and acknowledgment
timestamps, never evidence or subject references:

| Route | Effect |
|---|---|
| `GET /achievements` | Visible unlocks with this user's acknowledgment state |
| `GET /achievements/pending` | Visible unlocks this user has not acknowledged |
| `GET /achievements/pending?subject_type=job&subject_id=<id>` | Pending reveals about one Job or Epic; empty unless the user can access it |
| `POST /achievements/:id/acknowledge` | Acknowledge one unlock |
| `POST /achievements/:id/replay` | Make one reveal pending again for this user |
| `POST /achievements/reset_acknowledgments` | Clear this user's acknowledgments |
| `POST /admin/achievements/reset_acknowledgments` | Admin only: clear everyone's; requires `confirm=reset_all_acknowledgments` |

`GET /achievements` also lists locked definitions. A locked hidden definition
is reduced to its scope; nothing else about it is exposed. An unlock carries an
`evidence_link` (`kind`, `id`, `slug`) only when its subject is a Job or Epic the
caller can access, so an instance achievement never discloses a private record.

## Collection page and reveals

The **Achievements** sidebar page (`/achievements`) lists instance milestones and
the user's own accomplishments in separate sections, with earned times, evidence
links, locked and hidden placeholders, and per-unlock acknowledge and replay
controls plus a reset of the user's own acknowledgments. On the Job detail page
the plugin contributes a reveal host only while the user has an unacknowledged
reveal about that Job. Reveals appear oldest first, one at a time, and are
acknowledged only after being presented (visible tab). If saving fails, a retry
button is offered and the reveal stays pending. Reveals honor
`prefers-reduced-motion`, trap focus in an accessible dialog, and play no sound.
The placeholder artwork is deliberately neutral.

Replay and reset change acknowledgments only. They never delete or recreate an
unlock or alter its `unlocked_at` or evidence. While the plugin is disabled the
routes are not served and events are not evaluated.

## Launch behavior: no backfill

Enabling the plugin does **not** award achievements for history. Only events
that happen after it is enabled are evaluated, so a first enable starts with an
empty set. Any future backfill will be a separate, explicit operator action.

## Development workbench

The plugin contributes an admin page, **Achievements Workbench**
(`/admin/achievements_workbench`), only while both Achievements and Syrus Dev
are effectively enabled. Disabling either one removes the navigation entry and
makes `GET /api/v1/app/admin/achievements/workbench` return `404`; reveals,
the collection page, and evaluation are unaffected. It is admin only. Syrus Dev
contains nothing about achievements: the page, its API, its discussion flow, and
its tests all live in this plugin.

The workbench lists every registered definition (hidden ones included) with
filters for scope, category, rarity, trigger, visibility, and implementation
status. An implementation status is `implemented` when the trigger has an event
adapter and the evaluator class exists, `partial` when only one of those is true,
and `planned` otherwise. Fixtures are synthetic and never touch real unlocks;
each definition gets locked, unlocked, acknowledged, and reset states. They are
drawn by the production badge (`AchievementBadge`), collection cards, and reveal
(`AchievementRevealContent`, `AchievementRevealQueue`), not a copy of them.
Controls cover replaying the animation phases, a stack of reveals, phone, tablet
and desktop widths, system, reduced, or full motion, and an opt-in sound toggle
that is disabled until reveals have sound. The whole view (filters, definition,
state, viewport, motion, audio) is in the URL for sharing.

**Discuss with an agent** captures a screenshot of the preview (which can be
annotated; if capture fails the discussion still starts, noting that no
screenshot is attached), your prompt, and a structured context block with the
definition, fixture state, viewport, motion and audio settings, and a deep link,
then opens a new chat.

### Adding badge designs and animation variants

The later badge-design round works through the workbench:

1. Add or edit definitions in `Achievements::Catalog` (keep `example.*` fixtures
   until real names exist) with their `presentation` copy keys in the
   `achievements.json` locale files for English, German, and Latin.
2. Change artwork and animation only inside `AchievementBadge` and
   `AchievementRevealContent`/`revealMotionClasses`; the `data-rarity`,
   `data-category`, `data-scope`, and `data-state` attributes are the hooks for
   variants. Do not draw a second badge in the workbench.
3. Review each definition in every fixture state, at phone, tablet and desktop
   widths, with reduced motion on (the reveal must still convey the unlock
   without movement) and off, using **Replay animation** and the start/end phase
   buttons. Check a stacked reveal and the hidden definition's locked state,
   which must reveal nothing.
4. If sound is added, export the player from `workbench/soundSupport.ts` so the
   sound toggle and discussion payload pick it up.
5. Use **Discuss with an agent** on each definition to record the reviewed
   state; the deep link reproduces it exactly.
