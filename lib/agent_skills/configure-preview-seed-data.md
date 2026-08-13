---
name: configure-preview-seed-data
description: Make db/seeds.rb idempotent and add demo user + sample data so Syrus previews reach a populated, authenticated app state.
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
every "Start Preview" click. The seed command (`SyrusRails::PreviewProvider
#seed_command`, or the repo's own `.syrus.yml` `preview.seed`) runs against a
**fresh checkout every single time** — not once. A `db/seeds.rb` that isn't
idempotent (bare `Model.create!`) works on the first preview and then raises
a uniqueness violation, or silently duplicates rows, on the second. Making
seeding idempotent is a hard requirement of this skill, not a nice-to-have.

## What to do

1. **Inspect existing seed data.**
   - Read `db/seeds.rb` if it exists.
   - Check `db/fixtures/`, `test/fixtures/`, or `spec/fixtures/` for fixture
     data seeds might reuse.
   - Note which models are already seeded and how (`create!`,
     `find_or_create_by!`, bulk `import`, etc.).
   - This skill targets Rails apps (`Gemfile` + `db/seeds.rb` convention).
     If the repo has no `db/seeds.rb` and isn't a Rails app, stop here and
     leave a note in the PR description instead of guessing at an unfamiliar
     seed mechanism — don't invent one from scratch for a stack this skill
     doesn't recognize.

2. **Make seeding idempotent.** Rewrite any non-idempotent seed calls with
   `find_or_create_by!`/`find_or_initialize_by` guards. Example pattern:

   ```ruby
   # Row should always match the seed script exactly (e.g. demo
   # credentials) — repeat runs keep it in sync:
   demo_user = User.find_or_initialize_by(email_address: "demo@example.com")
   demo_user.assign_attributes(name: "Demo User", admin: false)
   demo_user.password = "password" if demo_user.new_record? || demo_user.password_digest.blank?
   demo_user.save!

   # Row is fine to create once and leave alone after that (safe for an
   # operator to edit during a preview session without every subsequent
   # preview stomping it):
   ["Action", "Comedy", "Drama"].each { |name| Genre.find_or_create_by!(name: name) }
   ```

   Guard rules:
   - Never use bare `Model.create!` for anything keyed by a natural unique
     attribute (email, slug, name) — it raises on the second seed run.
   - Prefer `find_or_create_by!` with a block when the row only needs to
     exist, not stay in sync with the script.
   - Prefer `find_or_initialize_by` + `assign_attributes` + `save!` when the
     row's attributes (like demo credentials) must always match what the
     script declares.
   - Wrap demo/sample data in an environment guard (e.g.
     `if Rails.env.development?`) — never seed demo rows into production.

3. **Add a demo user + representative sample data if the repo has none.**
   - A demo user with fixed, memorable credentials (e.g.
     `demo@example.com` / `password`) with enough permissions to reach the
     app's main authenticated surfaces.
   - A small number of representative records covering the app's primary
     models — enough that list/detail/dashboard views aren't empty, not a
     full fixture factory. A handful of rows per model is enough.
   - Skip this step if the repo already seeds a demo user and sample data;
     only fill genuine gaps.

4. **Write `seed_notes` into `.syrus.yml`.** The `visual_review:` block
   (documented in `config/syrus_docs/syrus_yml.md`) carries an optional
   `seed_notes` string the visual-review agent reads as a hint — it is never
   executed. Add or update it with 1-2 sentences describing how to reach an
   authenticated / populated view:

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

5. **Write specs.** Add or extend a seed spec (or Rake-task smoke test) that
   runs `db:seed` twice against a clean test database and asserts it
   succeeds both times without raising — this is the regression test for
   the idempotency requirement.

## Notes

- `db:seed` idempotency matters outside previews too: a fresh production
  deploy or a developer's local `db:setup` also runs it.
- Keep the sample data set small and representative, matching the existing
  seed philosophy in `db/seeds.rb` if the repo already has one.
- Don't touch unrelated parts of `.syrus.yml` — this skill's only
  `.syrus.yml` responsibility is `visual_review.seed_notes`.
