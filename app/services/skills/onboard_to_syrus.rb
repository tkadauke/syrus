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
  # PREPARE_SIGNALS for the `prepare:` section (mirrors every bundled
  # :prepare_detector plugin's own priority order, grouped by ecosystem —
  # RepoPrepPlan itself now delegates auto-detection to registered
  # plugins rather than a static table, so this skill keeps its own copy
  # instead of introspecting plugin internals; same pattern as
  # Skills::DependencyAudit's ECOSYSTEMS),
  # and RepoGradeSignals::RULE_DESCRIPTIONS for the `grade:` section
  # (a sibling detector built for this skill, directly unit-tested
  # against fixture repos — see spec/services/repo_grade_signals_spec.rb).
  class OnboardToSyrus < Base
    # Mirrors the bundled `ruby`, `javascript`, `python`, and `go`
    # :prepare_detector plugins, grouped by ecosystem. Within one
    # ecosystem, stop at the first matching signal file — only one
    # package manager is ever canonical for a given language. Across
    # ecosystems, every matching group contributes its command (a
    # Rails+React repo gets both `bundle install` and `npm ci`), mirroring
    # RepoPrepPlan's real union-across-plugins behavior.
    PREPARE_SIGNALS = {
      "Ruby" => [
        [ "Gemfile", "bundle install" ]
      ],
      "Node/JS" => [
        [ "yarn.lock",         "yarn install --frozen-lockfile" ],
        [ "pnpm-lock.yaml",    "pnpm install --frozen-lockfile" ],
        [ "package-lock.json", "npm ci" ],
        [ "package.json",      "npm install" ]
      ],
      "Python" => [
        [ "uv.lock",          "uv sync" ],
        [ "poetry.lock",      "poetry install" ],
        [ "requirements.txt", "pip install -r requirements.txt" ],
        [ "pyproject.toml",   "pip install -e ." ]
      ],
      "Go" => [
        [ "go.mod", "go mod download" ]
      ]
    }.freeze

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
      [ intro, pre_scan_section, step_by_step_instructions ].compact.join("\n\n")
    end

    private

    # Present only when a real on-disk checkout was available at
    # resolution time (Steps::RunSkill, once the shared workspace is
    # set up) — nil for every other resolution path (picker, chat
    # slash command, ScheduledTask fire), which fall back to the
    # generic step-by-step instructions below with no concrete
    # findings to report.
    def scan
      return nil unless @workspace_path

      @scan ||= {
        existing_config: Pathname.new(@workspace_path).join(SyrusYml::CONFIG_FILE).exist?,
        prep: RepoPrepPlan.for(@workspace_path),
        grade: RepoGradeSignals.for(@workspace_path)
      }
    end

    def intro
      <<~TXT.strip
        You are onboarding this repository to Syrus by producing a sensible
        `.syrus.yml` — the config file that tells Syrus how to install
        dependencies (`prepare:`) and validate changes (`grade:`) in this
        repository.

        Dry run: {{dry_run}}
      TXT
    end

    def pre_scan_section
      return nil unless scan

      <<~TXT.strip
        ## Automated pre-scan results

        Syrus already scanned this checkout before invoking you — use these
        findings as your starting point. The scan is deliberately shallow
        (plain file-existence checks plus a best-effort read of any CI
        workflow files), so verify each finding against the actual repo
        rather than trusting it blindly, and use the detection tables in
        the steps below to catch anything it missed.

        - `.syrus.yml`: #{existing_config_summary}
        - Detected prepare command: #{prep_summary}
        - Detected grade candidates: #{grade_candidates_summary}
        - Existing CI workflows: #{ci_summary}
      TXT
    end

    def existing_config_summary
      if scan[:existing_config]
        "already exists at the repo root. Do not overwrite it — produce a gap analysis instead (see Step 1)."
      else
        "does not exist. Write a new one from scratch (see Steps 2–4)."
      end
    end

    def prep_summary
      prep = scan[:prep]
      return "none — no recognized lockfile found" if prep.commands.empty?

      "`#{prep.commands.join(' && ')}` (source: #{prep.source})"
    end

    def grade_candidates_summary
      candidates = scan[:grade].candidates
      return "none detected" if candidates.empty?

      candidates.map { |c| "#{c.name} (`#{c.run}`, evidence: #{c.evidence})" }.join("; ")
    end

    def ci_summary
      grade = scan[:grade]
      return "none found" if grade.ci_workflow_paths.empty?

      commands = grade.ci_run_commands.any? ? " — run commands seen: #{grade.ci_run_commands.join('; ')}" : ""
      "#{grade.ci_workflow_paths.join(', ')}#{commands}"
    end

    def step_by_step_instructions
      <<~INSTRUCTIONS.strip
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

        Detect the package manager per ecosystem below. Within one
        ecosystem, check its signal files in this exact priority order and
        take only the first match — a repo never needs two package managers
        for the same language. A repo can match more than one ecosystem
        (e.g. a Rails app with a React frontend); include every ecosystem
        that matches, not just the first one. This mirrors the bundled
        prepare-detector plugins so the config you write agrees with what
        Syrus would already guess on its own:

        #{prepare_detection_table}

        If none of these files exist in any ecosystem, omit `prepare`
        entirely (or set it to `[]`) rather than guessing at a command.

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

    def prepare_detection_table
      PREPARE_SIGNALS.map do |ecosystem, signals|
        rows = signals.map { |file, command| "  - `#{file}` → `#{command}`" }.join("\n")
        "- **#{ecosystem}**:\n#{rows}"
      end.join("\n")
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
