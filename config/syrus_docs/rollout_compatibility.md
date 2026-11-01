# Rollout Compatibility

Syrus deploys by rolling replicas, so there is always a window in which two
versions of the application are running against one database. Every release
must survive that window. The rule is that **each release is compatible with
the one before it, in both directions**:

1. **New code must run against the old schema.** Migrations run before the
   rollout, but ActiveRecord defines attribute methods from the column list
   cached when a process booted. A process that started before the migration
   has no method for a column added after it, however long ago the column
   landed. New code that reads a new column unconditionally will raise
   `NoMethodError` somewhere in that window.
2. **Old code must run against the new schema.** Old replicas keep serving for
   the whole rollout, and `bin/deploy` can roll image overrides back after
   migrations have already applied. A release may therefore only *add*. Never
   drop, rename, or narrow a column in the same release that stops using it.

Both halves have cost this codebase a production incident.

- Rule 2: `pr_check_gate` replaced `land_on_inherited_check_failure` and
  dropped it in the same release. Old replicas kept selecting the missing
  column, and the fix was a migration whose name says what it was for --
  `RestoreLandOnInheritedCheckFailureForRollingDeploys` -- adding the column
  back mid-incident.
- Rule 1: `contained_chat_execution` was added and read in the same release.
  During the rollout, chat turns raised
  `NoMethodError: undefined method 'contained_chat_execution'` against a
  pre-migration schema snapshot.

## Expand, migrate, contract

Spread a schema change across three releases. Only the last one removes
anything, and only once no running version reads it.

| release | schema | code |
| --- | --- | --- |
| **expand** | add the new column; additive only | read it defensively, tolerating absence; keep writing the old one |
| **migrate** | backfill | read the new column normally; stop writing the old one |
| **contract** | drop the old column | nothing references it |

A two-release version is fine when there is no old column to retire: expand
(add + defensive read), then migrate (plain read).

## Reading defensively

`has_attribute?` is the check, and the fallback should be the value the
feature would have had before it existed -- usually its default:

```ruby
def self.contained_chat_execution
  setting = current
  return "off" unless setting.has_attribute?(:contained_chat_execution)

  setting.contained_chat_execution.presence_in(CONTAINED_CHAT_EXECUTION_MODES) || "off"
end
```

Guard validations the same way, since a validation on an attribute the schema
snapshot does not have raises when the record is saved:

```ruby
validates :contained_chat_execution,
  inclusion: { in: CONTAINED_CHAT_EXECUTION_MODES },
  if: -> { has_attribute?(:contained_chat_execution) }
```

The guard is removable in the *next* release, once every running process has
booted against the new schema. It is not permanent clutter; it is the expand
phase doing its job.

## What this does not cover

A gentler failure is still a failure. The service worker added for deploys
(see `deploy.md`) replaces the proxy's "Bad Gateway" with a "Syrus is getting
ready" page during a rollout, but it cannot help here: the application loads
successfully and then raises. Split-brain is a compatibility problem, not a
presentation one.

Equally, migrations running before the rollout does not make rule 1
unnecessary. The ordering guarantees the *database* is ready; it guarantees
nothing about the column caches of processes already running, or of processes
that boot from the old image during a partial rollout or a rollback.
