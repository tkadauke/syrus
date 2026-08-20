module Skills
  # Built-in skill (EPIC-234): bootstraps a GitHub Actions CI workflow
  # wired to the exact command set this repo already grades with — pulled
  # from `.syrus.yml`'s `grade` section (preferring each step's `ci:`
  # variant, via RepoGradePlan's legacy `-ci` grader expansion), or
  # `onboard-to-syrus`'s auto-detected equivalent (RepoGradeSignals) when
  # no grade section is configured yet. CI and Syrus's own grading must
  # read from the same command set instead of drifting into two
  # separately-maintained lists — that's the whole point of this skill.
  #
  # If CI config already exists — a GitHub Actions workflow under
  # `.github/workflows/`, or evidence of another CI system (GitLab CI,
  # CircleCI, Jenkins, Drone) — this skill never overwrites it. It
  # produces a gap report of resolved commands missing from the existing
  # setup instead, the same "detect first, never clobber operator config"
  # discipline Skills::OnboardToSyrus applies to `.syrus.yml` itself.
  #
  # Where a real on-disk checkout is available (currently only
  # Steps::RunSkill), a Ruby-side pre-scan resolves the command set,
  # locates existing CI config, and computes the gap (a literal substring
  # search for each resolved command across the existing CI files' raw
  # text — deliberately format-agnostic since GitLab/CircleCI/Jenkins/
  # Drone configs aren't YAML-job-shaped the way GitHub Actions is) so the
  # agent's instructions start from concrete findings.
  class AddCiWorkflow < Base
    OTHER_CI_SIGNALS = [
      [ ".gitlab-ci.yml", "GitLab CI" ],
      [ ".circleci/config.yml", "CircleCI" ],
      [ "Jenkinsfile", "Jenkins" ],
      [ ".drone.yml", "Drone" ]
    ].freeze

    DEFAULT_WORKFLOW_PATH = ".github/workflows/ci.yml".freeze

    def self.skill_name
      "add-ci-workflow"
    end

    def self.description
      "Bootstraps a GitHub Actions CI workflow wired to the same command set this repo already " \
        "grades with, or reports gaps against an existing CI setup instead of overwriting it."
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
    # resolution time (Steps::RunSkill, once the shared workspace is set
    # up) — nil for every other resolution path (picker, chat slash
    # command, ScheduledTask fire), which fall back to the generic
    # step-by-step instructions below with no concrete findings to report.
    def scan
      return nil unless @workspace_path

      @scan ||= {
        resolved_commands: resolved_commands,
        existing_ci_files: existing_ci_files,
        gaps: gaps
      }
    end

    def path
      @path ||= Pathname.new(@workspace_path)
    end

    # Prefer commands Syrus already grades with (`.syrus.yml`'s `grade`
    # section, `ci:` variant preferred over `run:`); fall back to the
    # same auto-detected candidates onboard-to-syrus would propose for a
    # repo with no `grade` section configured yet.
    #
    # RepoGradePlan expands a step with both `run:` and `ci:` into two
    # Grader rows (the base grader plus a `<name>-ci` legacy-ci grader
    # tagged via `metadata["legacy_source_grader"]`) rather than exposing
    # a per-variant accessor — group back to the original step name and
    # prefer its `-ci` row when present.
    def resolved_commands
      grade_plan = RepoGradePlan.for(@workspace_path)
      if grade_plan.graders.any?
        by_step_name = grade_plan.graders.group_by { |grader| grader.metadata["legacy_source_grader"] || grader.name }
        return by_step_name.map do |step_name, graders|
          preferred = graders.find { |grader| grader.metadata["legacy_ci_command"] } || graders.first
          { name: step_name, command: preferred.command, source: ".syrus.yml (grade section)" }
        end
      end

      RepoGradeSignals.for(@workspace_path).candidates.map do |candidate|
        { name: candidate.name, command: candidate.run, source: "auto-detected (grade signals)" }
      end
    end

    def existing_ci_files
      gha = Dir.glob(path.join(RepoGradeSignals::CI_WORKFLOW_GLOB).to_s).sort
        .map { |p| Pathname.new(p).relative_path_from(path).to_s }
        .map { |rel| { path: rel, system: "GitHub Actions" } }

      other = OTHER_CI_SIGNALS.filter_map do |rel, system|
        { path: rel, system: system } if path.join(rel).exist?
      end

      gha + other
    end

    # Deliberately shallow: a literal substring search for each resolved
    # command across the raw text of every existing CI file, rather than
    # a per-system-format-aware parse (RepoGradeSignals already does that
    # for GitHub Actions specifically). Format-agnostic so it works the
    # same whether the existing CI is a GitHub Actions workflow or a
    # GitLab/CircleCI/Jenkins/Drone config — at the cost of both false
    # positives (a command that appears in a comment) and false negatives
    # (a command run through a wrapper script) that the agent must verify
    # against the real files rather than trust blindly.
    def gaps
      return [] if existing_ci_files.empty?

      combined_text = existing_ci_files.map { |f| read_ci_file(f[:path]) }.join("\n")
      resolved_commands.reject { |rc| combined_text.include?(rc[:command]) }
    end

    def read_ci_file(rel)
      path.join(rel).read
    rescue Errno::ENOENT, Errno::EISDIR
      ""
    end

    def intro
      <<~TXT.strip
        You are bootstrapping continuous integration for this repository:
        wire a CI workflow to the exact command set Syrus already grades
        this repo with, so CI and Syrus's own grading never drift into two
        separately-maintained lists. If CI config already exists, you
        report gaps instead — you never overwrite it.

        Dry run: {{dry_run}}
      TXT
    end

    def pre_scan_section
      return nil unless scan

      <<~TXT.strip
        ## Automated pre-scan results

        Syrus already scanned this checkout before invoking you — use
        these findings as your starting point. Verify each finding
        against the actual repo rather than trusting it blindly,
        especially the gap list below, which is a literal substring
        search and can both over- and under-match.

        - Resolved command set: #{resolved_commands_summary}
        - Existing CI config: #{existing_ci_summary}
        - Gaps (resolved commands not found in existing CI config): #{gaps_summary}
      TXT
    end

    def resolved_commands_summary
      commands = scan[:resolved_commands]
      return "none — no configured graders or detected grade signals" if commands.empty?

      commands.map { |c| "#{c[:name]} (`#{c[:command]}`, source: #{c[:source]})" }.join("; ")
    end

    def existing_ci_summary
      files = scan[:existing_ci_files]
      return "none found" if files.empty?

      files.map { |f| "#{f[:path]} (#{f[:system]})" }.join("; ")
    end

    def gaps_summary
      return "n/a — no existing CI config to compare against" if scan[:existing_ci_files].empty?

      gaps = scan[:gaps]
      return "none — every resolved command already appears in the existing CI config" if gaps.empty?

      gaps.map { |c| "#{c[:name]} (`#{c[:command]}`)" }.join("; ")
    end

    def step_by_step_instructions
      <<~INSTRUCTIONS.strip
        ## Step 1 — resolve the command set

        Determine the exact command set to wire into CI, in this priority
        order:

        1. If `.syrus.yml` has a `grade` section configured, use its
           steps — for each one, prefer the `ci:` command when present,
           otherwise fall back to `run:`. This is the same preference
           Syrus's own grading uses (RepoGradePlan's `ci:` grader
           expansion) so CI runs the identical isolated-serial variant Syrus's own
           `ci_failure` and main-branch graders use.
        2. If there is no `grade` section configured yet, fall back to
           the same auto-detected candidates `onboard-to-syrus` would
           propose — inspect the repository for the signals in this
           table:

           #{grade_detection_table}

        Never invent a command that isn't backed by one of these two
        sources — the whole point of this skill is that CI and Syrus's
        own grading read from the same list.

        ## Step 2 — check for existing CI config

        Look for:

        - A GitHub Actions workflow under `.github/workflows/*.yml` or
          `.github/workflows/*.yaml`.
        - Evidence of another CI system: #{other_ci_detection_table}

        If **any** of these exist, do not create, overwrite, or reorder
        any CI config file. Proceed to Step 3 (gap report) instead of
        Step 4 (bootstrap).

        If **none** exist, proceed to Step 4 (bootstrap) and skip Step 3.

        ## Step 3 — gap report (existing CI config found)

        For each command resolved in Step 1, determine whether it already
        runs somewhere in the existing CI config. Read the existing
        file(s) yourself rather than trusting the pre-scan's substring
        match alone — a command can be present but run through a wrapper
        script (a false negative in the pre-scan) or merely mentioned in
        a comment (a false positive).

        Produce a gap report as your final output: for each resolved
        command, state whether it's covered by the existing CI config or
        missing. If everything is already covered, say so plainly. Make
        no changes — this always closes without a diff, which is a valid,
        successful outcome; it closes without opening a PR.

        ## Step 4 — bootstrap (no existing CI config found)

        Generate a new GitHub Actions workflow at `#{DEFAULT_WORKFLOW_PATH}`
        (or another descriptive path under `.github/workflows/` if that
        one is already taken for an unrelated purpose) that:

        - Triggers on `push` and `pull_request` against the repository's
          default branch.
        - Checks out the repository.
        - Sets up whatever runtime(s) the resolved commands need (e.g.
          `actions/setup-ruby` with Bundler caching for a `Gemfile`,
          `actions/setup-node` for a `package.json`/lockfile) — base this
          on the same lockfile signals Syrus's own `prepare:`
          auto-detection uses, not a guess.
        - Installs dependencies the same way Syrus's own `prepare:` step
          would (or the repo's own `.syrus.yml` `prepare:` commands, if
          configured).
        - Runs every command resolved in Step 1, each as its own step so
          a failure is individually attributable.

        If dry run is `true`: do not create or write any file. Produce
        the proposed workflow YAML as your final report instead. Make no
        commit.

        If dry run is not `true`: write the workflow file and commit it.
      INSTRUCTIONS
    end

    def grade_detection_table
      RepoGradeSignals::RULE_DESCRIPTIONS.map { |rule| "- **#{rule.name}** (`#{rule.run}`) — #{rule.signals}" }.join("\n")
    end

    def other_ci_detection_table
      OTHER_CI_SIGNALS.map { |rel, system| "`#{rel}` (#{system})" }.join(", ")
    end
  end
end
