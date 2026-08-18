module Skills
  # Built-in skill (EPIC-234): scans a newly-attached repository and
  # writes a sensible `.syrus.yml`, or — if one already exists — reports
  # a gap analysis instead of silently overwriting operator-authored
  # config. Skills are freeform instruction sets that resist
  # decomposition into the deterministic Workflow/Step pipeline (see
  # config/syrus_docs/skills.md), so the actual repo scan is agent-
  # driven, not a Ruby-side Step handler — mirroring Skills::Investigate.
  #
  # The instructions embed two Syrus-native detection tables so the
  # agent's own scan can't drift from what Syrus already knows:
  # RepoPrepPlan::AUTO_DETECT for the `prepare:` section (reused
  # verbatim, per the issue's "don't reimplement lockfile detection"),
  # and RepoGradeSignals::RULE_DESCRIPTIONS for the `grade:` section
  # (a sibling detector built for this skill, directly unit-tested
  # against fixture repos — see spec/services/repo_grade_signals_spec.rb).
  class OnboardToSyrus < Base
    def self.skill_name
      "onboard-to-syrus"
    end

    def self.description
      "Scans a newly-attached repository and writes a sensible .syrus.yml " \
        "(prepare + grade sections), or reports a gap analysis if one already exists."
    end

    def self.parameter_schema
      [
        { key: "dry_run", type: "boolean", required: false, label: "Dry run", default: false }
      ]
    end

    def to_s
      <<~INSTRUCTIONS
        You are onboarding this repository to Syrus by producing a sensible
        `.syrus.yml` — the config file that tells Syrus how to install
        dependencies (`prepare:`) and validate changes (`grade:`) in this
        repository.

        Dry run: {{dry_run}}

        ## Step 1 — check for an existing .syrus.yml

        Look for a `.syrus.yml` at the repository root.

        - If it **already exists**, do not overwrite, reorder, or reformat
          it. Instead, compare what it already configures against what the
          repository's own tooling suggests (Steps 2 and 3 below) and
          produce a **gap analysis**: a plain report listing any `prepare`
          or `grade` entries that look missing, with the evidence that
          justified each suggestion. Never edit, remove, or silently
          replace anything the operator already wrote. If the existing
          config already looks complete, say so and make no changes.
        - If **no `.syrus.yml` exists**, proceed to Steps 2 and 3 and write
          a new one from scratch.

        ## Step 2 — prepare: (dependency install)

        Detect the package manager from these signal files, in this exact
        priority order — stop at the first match. This mirrors Syrus's own
        auto-detect table (`RepoPrepPlan::AUTO_DETECT`) so the config you
        write agrees with what Syrus would already guess on its own:

        #{prepare_detection_table}

        If none of these files exist, omit `prepare` entirely (or set it to
        `[]`) rather than guessing at a command.

        ```yaml
        prepare:
          - bundle install
          - npm ci
        ```

        ## Step 3 — grade: (validation commands)

        Inspect the repository for testing, linting, typecheck, and CI
        tooling and propose one `grade.steps` entry per tool you find real
        evidence for. Check for:

        #{grade_detection_table}

        Also look for existing CI config under `.github/workflows/*.yml` /
        `.github/workflows/*.yaml`. If you find any, **read them** and
        prefer the exact commands they already run over inventing new
        ones — CI is the strongest signal for "this is the command that
        actually validates this repository."

        Each `grade.steps` entry uses this shape (see the `.syrus.yml`
        reference for the full schema):

        ```yaml
        grade:
          steps:
            - name: rspec
              run: bin/rspec
              required: true
              timeout_minutes: 15
        ```

        #{grade_step_schema_table}

        Prefer a command the repository itself already exposes (an npm
        script, a Rake task, a Makefile target, a CI step) over inventing
        an ad hoc tool invocation. Default every step to `required: true`;
        only mark one `required: false` when you have a concrete reason to
        believe it's advisory-only (e.g. a known-flaky or best-effort
        check).

        ## Step 4 — write or report

        If dry run is `true`: do not create, modify, or write any files.
        Produce your findings as your final written report instead — for
        each `prepare`/`grade` entry you would add (or, when gap-analyzing
        an existing file, each gap you found), state the proposed YAML and
        the evidence that justified it. Make no commit.

        If dry run is not `true`:

        - When no `.syrus.yml` exists, write the file with the `prepare`
          and `grade` sections you determined above, and commit it.
        - When a `.syrus.yml` already exists, leave it untouched — write
          your gap analysis as your final report instead of editing it.

        If you find nothing to add — an already-complete `.syrus.yml`, or a
        repository with no detectable `prepare`/`grade` signals at all —
        say so plainly and make no changes. That is a valid, successful
        outcome: an onboarding run with nothing to do closes without a PR.
      INSTRUCTIONS
    end

    private

    def prepare_detection_table
      RepoPrepPlan::AUTO_DETECT.map { |file, command| "- `#{file}` → `#{command}`" }.join("\n")
    end

    def grade_detection_table
      RepoGradeSignals::RULE_DESCRIPTIONS.map do |rule|
        "- **#{rule.name}** (`#{rule.run}`) — #{rule.signals}"
      end.join("\n")
    end

    def grade_step_schema_table
      <<~TABLE.strip
        - `name` — required; alphanumeric characters and hyphens only, unique within `grade.steps`
        - `run` — required; the shell command to run
        - `required` — optional, defaults to `true`; set `false` for advisory-only checks
        - `timeout_minutes` — optional, defaults to 15 (max 90)
      TABLE
    end
  end
end
