---
name: configure-preview-seed-data
description: Make the repo's seed mechanism idempotent and add demo user + sample data so Syrus previews reach a populated, authenticated app state.
allowed-tools:
  - Read
  - Edit
  - Write
  - Bash(ls:*)
  - Bash(cat:*)
  - Bash(find:*)
  - Bash(grep:*)
---

# Seed idempotent demo data for previews

This is a one-time, per-repo onboarding pass, not a recurring maintenance
task. An operator runs it once when turning on previews / visual review for
a repository. Its output is itself a PR to review and merge — say so in the
PR title/description.

## Why this matters

Syrus starts a preview of this repo before every visual-review pass and on
every "Start Preview" click. The seed command (the repo's own `.syrus.yml`
`preview.seed`, or a framework default such as
`SyrusRails::PreviewProvider#seed_command`) runs against a **fresh checkout
every single time** — not once. A seed script that isn't idempotent (bare
`create` calls with no uniqueness guard) works on the first preview and then
raises on a uniqueness violation, or silently duplicates rows, on the
second. Making seeding idempotent is a hard requirement of this skill, not
a nice-to-have, regardless of which framework or language the repo uses.

## What to do

1. **Detect the repo's seed mechanism.** Don't assume Rails. Look for
   whichever of these actually exists in the repo root (check in this
   order and use the first match):

   | Signal | Framework | Typical seed entry point |
   |---|---|---|
   | `Gemfile` + `db/seeds.rb` | Rails | `db/seeds.rb`, run via `bin/rails db:seed` |
   | `manage.py` + a `seed`/`loaddata` command or fixtures | Django | a custom management command, or `python manage.py loaddata <fixture>` |
   | `artisan` + `database/seeders/` | Laravel | `database/seeders/DatabaseSeeder.php`, run via `php artisan db:seed` |
   | `prisma/schema.prisma` + `prisma/seed.*` | Node/Prisma | `prisma/seed.ts`/`.js`, run via `npx prisma db seed` |
   | `package.json` with a `seed` script (no Prisma) | Node (other ORM) | whatever the `seed` script points at (Knex, Sequelize, Drizzle, TypeORM, raw SQL) |
   | `go.mod` with a `cmd/seed` or `seed.go` | Go | a custom seed binary/command |
   | none of the above | unrecognized | see step 1a |

   Also check `db/fixtures/`, `test/fixtures/`, or `spec/fixtures/` (or the
   language's fixture-equivalent) for data seeds might already reuse, and
   check the current `.syrus.yml` `preview.seed` key if one is already set
   — it tells you the exact command Syrus runs today.

   1a. **If the repo's seed mechanism isn't one of the recognized shapes
       above**, don't invent one from scratch. Read whatever setup/README
       docs the repo has for local development seeding, and hand-roll the
       smallest idempotent seed script that fits the repo's existing
       conventions (migration tool, ORM, query builder). Say in the PR
       description which mechanism you chose and why, since there was no
       established convention to follow.

2. **Make seeding idempotent.** The exact syntax depends on the framework,
   but the guard rule is the same everywhere: never insert a row keyed by a
   natural unique attribute (email, slug, name) without first checking
   whether it already exists.

   Rails (`find_or_create_by!` / `find_or_initialize_by`):

   ```ruby
   # Row should always match the seed script exactly (e.g. demo
   # credentials) — repeat runs keep it in sync:
   demo_user = User.find_or_initialize_by(email_address: "demo@example.com")
   demo_user.assign_attributes(name: "Demo User", admin: false)
   demo_user.password = "password" if demo_user.new_record? || demo_user.password_digest.blank?
   demo_user.save!

   # Row is fine to create once and leave alone after that:
   ["Action", "Comedy", "Drama"].each { |name| Genre.find_or_create_by!(name: name) }
   ```

   Django (`update_or_create` / `get_or_create`):

   ```python
   User.objects.update_or_create(
       email="demo@example.com",
       defaults={"name": "Demo User", "is_staff": False},
   )
   Genre.objects.get_or_create(name="Action")
   ```

   Laravel (`updateOrCreate` / `firstOrCreate`):

   ```php
   User::updateOrCreate(
       ['email' => 'demo@example.com'],
       ['name' => 'Demo User', 'is_admin' => false]
   );
   Genre::firstOrCreate(['name' => 'Action']);
   ```

   Node/Prisma (`upsert`):

   ```ts
   await prisma.user.upsert({
     where: { email: "demo@example.com" },
     update: { name: "Demo User" },
     create: { email: "demo@example.com", name: "Demo User", role: "member" },
   });
   ```

   Other stacks: use whatever upsert/find-or-create primitive the ORM or
   query builder provides. If the stack has none, guard manually — select
   by the unique key first, then insert only when nothing came back.

   General guard rules, regardless of language:
   - Prefer a "get or create, don't touch existing attributes" call when
     the row only needs to exist, not stay in sync with the script.
   - Prefer a "find or initialize, then assign and save" call when the
     row's attributes (like demo credentials) must always match what the
     script declares.
   - Wrap demo/sample data in an environment guard (development/local
     only, whatever the framework's idiom is) — never seed demo rows into
     production.

3. **Add a demo user + representative sample data if the repo has none.**
   - A demo user with fixed, memorable credentials (e.g.
     `demo@example.com` / `password`) with enough permissions to reach the
     app's main authenticated surfaces.
   - A small number of representative records covering the app's primary
     models/entities — enough that list/detail/dashboard views aren't
     empty, not a full fixture factory. A handful of rows per model is
     enough.
   - Skip this step if the repo already seeds a demo user and sample data;
     only fill genuine gaps.

4. **Write `seed_notes` into `.syrus.yml`.** The `visual_review:` block
   (documented in `config/syrus_docs/syrus_yml.md`) carries an optional
   `seed_notes` string the visual-review agent reads as a hint — it is
   never executed. Add or update it with 1-2 sentences describing how to
   reach an authenticated / populated view:

   ```yaml
   visual_review:
     seed_notes: "Sign in at /login as demo@example.com / password to reach the populated dashboard."
   ```

   Preserve every other key already present in `.syrus.yml`, including the
   rest of the `visual_review:` block (`enabled`, `rounds`,
   `when_files_changed`) — only add or replace `seed_notes`. If `.syrus.yml`
   has no `visual_review:` block yet, don't invent the whole block; note in
   the PR description that `seed_notes` can't be written until visual review
   is configured for this repo (a separate onboarding step).

   If the repo's `.syrus.yml` has no `preview.seed` command and the
   framework isn't one Syrus auto-detects a default seed command for, also
   add one pointing at the seed entry point you made idempotent (see
   `config/syrus_docs/preview_environments.md` for the `preview:` block
   shape) — otherwise the idempotent seed script you wrote never actually
   runs against previews.

5. **Write specs.** Add or extend a test in the repo's existing test
   framework that runs the seed command twice against a clean test
   database and asserts it succeeds both times without raising — this is
   the regression test for the idempotency requirement. Use whatever the
   repo already uses for this kind of test (RSpec, pytest, PHPUnit, Jest,
   Go's `testing`, etc.) — don't introduce a new test framework for this.

## Notes

- Seed idempotency matters outside previews too: a fresh production deploy
  or a developer's local environment setup also runs the seed command.
- Keep the sample data set small and representative, matching the existing
  seed philosophy already in the repo, if it has one.
- Don't touch unrelated parts of `.syrus.yml` — this skill's `.syrus.yml`
  responsibilities are `visual_review.seed_notes` and, only when missing,
  `preview.seed`.
