# Queues and databases map

## Queues

Solid Queue configuration and recurring schedules live in `config/queue.yml`
and `config/recurring.yml`; deployed worker process/queue selection lives in
the deployment configuration. Every `ApplicationJob` declares `queue_as` and
must target a queue consumed by at least one deployed worker. Runtime placement
also considers WorkUnit ownership, concurrency gates, priority, and
`RunQueueResolver` capabilities.

The important queue families and exact consumers are asserted by configuration
and architecture specs. Read those files rather than copying a queue list into
prose that will drift.

## Databases and state

| Data | Owner/location |
| --- | --- |
| Application records | Active Record models in `app/models/`, schema in `db/schema.rb` |
| Migrations | `db/migrate/` |
| Queue records | Solid Queue tables in production; tests use the configured single-database setup |
| Cache | Solid Cache configuration and tables |
| Cable | Solid Cable configuration and tables |
| Search/index records | core or plugin-owned models and migrations for the relevant subsystem |
| Workspace files | worker filesystem under `$SYRUS_DATA_ROOT`, not relational storage |
| Attachments | Active Storage configuration in `config/storage.yml` and attachment models |

Development/test use SQLite and production uses MySQL. Schema changes follow
[Database and migration conventions](../conventions/database-and-migrations.md);
do not assume SQLite behavior proves MySQL compatibility.
