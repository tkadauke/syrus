# Achievements

The `achievements` plugin owns achievement definitions, canonical unlocks, and
per-user acknowledgments. It is disabled by default, experimental, and can be
toggled in **Admin → Plugins**. The bundled definitions are neutral `example.*`
fixtures rather than a launch catalog; presentation and the development
workbench arrive separately.

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
| `POST /achievements/:id/acknowledge` | Acknowledge one unlock |
| `POST /achievements/:id/replay` | Make one reveal pending again for this user |
| `POST /achievements/reset_acknowledgments` | Clear this user's acknowledgments |
| `POST /admin/achievements/reset_acknowledgments` | Admin only: clear everyone's; requires `confirm=reset_all_acknowledgments` |

Replay and reset change acknowledgments only. They never delete or recreate an
unlock or alter its `unlocked_at` or evidence. While the plugin is disabled the
routes are not served and events are not evaluated.

## Launch behavior: no backfill

Enabling the plugin does **not** award achievements for history. Only events
that happen after it is enabled are evaluated, so a first enable starts with an
empty set. Any future backfill will be a separate, explicit operator action.
