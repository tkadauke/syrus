# Database and migrations

Use these rules for persistence, ownership invariants, migrations, and backfills across SQLite development and MySQL production.

- **Encrypted attributes** — `User#github_token`, `User#claude_oauth_token`
  use Active Record Encryption. Means `RAILS_MASTER_KEY` is required in
  any process that touches them. Smoke tests inside containers without
  the key will fail at User creation — by design. Production may supply
  `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`,
  `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`, and
  `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` instead of credentials;
  set all three together or boot fails.
- **Execution ownership** — `Workflow#user_id` and `Run#user_id` must match
  the parent Job owner. Creation paths default from `job.user`; tests and
  manual records should do the same because `RunJob` refuses mismatched
  execution graphs.
- **Job/Epic ownership** — `owner_user_id` is the durable assignee used
  by dashboard scopes, admin APIs, and Epic-owned child Jobs. Job
  `claimed_by_user_id` / `claimed_at` is a lightweight app claim shown in
  the dashboard and Job detail; only the current claimant can release it.
  Keep `mine`, `team`, `claimable`, and explicit `user` scopes aligned
  across dashboard payloads, API serializers, and React filters.
- **Migration timestamps come from the generator. No exceptions.**
  Always create migrations with `bin/rails generate migration <Name>`.
  Never hand-write a `db/migrate/YYYYMMDDHHMMSS_*.rb` filename, never
  copy a sibling migration and bump the digits, never reuse a timestamp
  you saw in another branch's PR. Hand-rolled timestamps collide:
  two branches that both pick `20260513120100` produce identical
  `schema_migrations` rows on the first environment to merge them, and
  the second branch's file then crashes the deploy with
  `Mysql2::Error: Table 'X' already exists`. Recovery is manual
  `UPDATE schema_migrations SET version = '<new>' WHERE version =
  '<old>'` SQL in every environment (dev, test, staging, production) —
  we have paid for this several times. This applies to backfills,
  schema-version bumps, no-op migrations, every kind. If you regret a
  hand-written file you already committed, delete it, regenerate via
  the generator, and rewrite the diff onto the new file before
  pushing.
- **Migrations are idempotent.** Wrap every `add_column`,
  `remove_column`, `add_reference`, `remove_reference`, and
  `add_index` in an existence guard:

  ```ruby
  def up
    add_column :jobs, :approved_at, :datetime unless column_exists?(:jobs, :approved_at)
    add_reference :jobs, :approved_by_user, null: true, index: true unless column_exists?(:jobs, :approved_by_user_id)
    add_index :jobs, :approved_at unless index_exists?(:jobs, :approved_at)
  end
  ```

  Why: production migrations occasionally crash partway through (OOM,
  pod eviction, transient lock contention, etc.) and don't record the
  version in `schema_migrations`. On retry the bare `add_column` dies
  with `Mysql2::Error: Duplicate column name`, the init container
  loops, the deploy hangs. Idempotent migrations recover instead. The
  same applies to `down`: guard with `if column_exists?` so a rollback
  on a partial-state DB doesn't crash. `add_table` / `drop_table` are
  less critical (table creation is more atomic) but follow the pattern
  anyway — `create_table :foo do |t|` becomes `create_table :foo,
  if_not_exists: true do |t|` with no behavior change.
- **JSON columns can't have defaults on MySQL 8.** `add_column :jobs,
  :payload, :json, default: {}, null: false` runs fine on SQLite (dev /
  test) and crashes the production migration with `BLOB, TEXT, GEOMETRY
  or JSON column 'payload' can't have a default value`. The pattern
  that works:

  ```ruby
  add_column :jobs, :payload, :json
  execute "UPDATE jobs SET payload = '{}' WHERE payload IS NULL"
  change_column_null :jobs, :payload, false
  ```

  Add an `after_initialize` callback on the model that seeds `{}` for
  new records so the column stays non-null going forward without a DB
  default. Copy an existing guarded JSON-column pattern.
- **Nontrivial backfills are maintenance tasks, not ad hoc jobs.** When a
  change needs historical data reclassified/reconciled/backfilled at
  more-than-trivial scale, implement it as a `MaintenanceTasks::Definitions::Base`
  subclass (`app/services/maintenance_tasks/definitions/`), registered in
  `MaintenanceTasks::Registry`, not as a bare `ApplicationJob` an operator has
  to remember to `perform_later` by hand. The framework gives it a discovered
  pending state (`MaintenanceTasks::Discovery`), operator start/pause/resume/
  cancel controls (`MaintenanceTasks::Actions`), checkpointed batch resumption
  (`MaintenanceTasks::Runner`), and admin/MCP visibility
  (`admin_maintenance_tasks` MCP tool, Maintenance Tasks admin page) for free.
  A plugin-owned backfill keeps its actual query/update logic in the plugin
  (a plain service object with `.pending_count` and `#call`); the Definition
  subclass itself lives in core and references the plugin service by string
  via `safe_constantize`, mirroring
  `MaintenanceTasks::Definitions::StaleInsightBacklogRetirement` — never a
  hard `require`/constant reference from core into a disableable plugin, since
  that breaks the plugin's deletability (`bin/plugin-boundary-audit`). A
  one-off migration-time backfill that touches only a handful of rows, or one
  that must run synchronously inside the migration itself, doesn't need this —
  use judgment on "nontrivial."
