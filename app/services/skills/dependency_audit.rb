module Skills
  # Built-in skill (EPIC-234): detects the repo's package manager(s) via the
  # same lockfile signals RepoPrepPlan uses for `prepare:` (Gemfile,
  # yarn.lock, pnpm-lock.yaml, package-lock.json, package.json), runs the
  # ecosystem-appropriate dependency audit command for each one detected,
  # and either reports flagged vulnerabilities (dry run, the default) or
  # bumps the flagged dependencies to their patched versions and commits —
  # always running the repo's own grade commands first, so a bump that
  # breaks the build never gets pushed.
  #
  # Unlike RepoPrepPlan::AUTO_DETECT (which picks exactly one install
  # command per repo — the first lockfile match wins, full stop), this skill
  # detects independently *per ecosystem*: a poly-ecosystem repo (Gemfile +
  # package-lock.json, e.g. this one) needs both `bundle audit` and `npm
  # audit` run, not just the first hit. Within a single ecosystem's own
  # lockfile family (yarn.lock vs. pnpm-lock.yaml vs. package-lock.json vs.
  # package.json), the same first-match-wins priority order still applies —
  # only one Node package manager is ever canonical for a given repo.
  #
  # No vulnerabilities found in any detected ecosystem is the explicit happy
  # path: report that and make no changes, which Steps::RunSkill's existing
  # no_changes handling turns into a successful Job close with no PR —
  # mirroring how Skills::Debug's failed-reproduction path and
  # Skills::OnboardToSyrus's already-complete-config path both end.
  class DependencyAudit < Base
    RUBY_ECOSYSTEM = [
      [ "Gemfile", "bundle audit" ]
    ].freeze

    NODE_ECOSYSTEM = [
      [ "yarn.lock", "yarn audit" ],
      [ "pnpm-lock.yaml", "pnpm audit" ],
      [ "package-lock.json", "npm audit" ],
      [ "package.json", "npm audit" ]
    ].freeze

    ECOSYSTEMS = { "Ruby" => RUBY_ECOSYSTEM, "Node" => NODE_ECOSYSTEM }.freeze

    def self.skill_name
      "dependency-audit"
    end

    def self.description
      "Runs the repo's ecosystem-appropriate dependency audit command(s) and either reports " \
        "flagged vulnerabilities (dry run, the default) or bumps them to patched versions and commits."
    end

    def self.parameter_schema
      [
        { key: "dry_run", type: "boolean", required: false, label: "Dry run", default: true }
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
        ecosystems: detected_ecosystems,
        configured_graders: RepoGradePlan.for(@workspace_path),
        grade_signals: RepoGradeSignals.for(@workspace_path)
      }
    end

    def detected_ecosystems
      path = Pathname.new(@workspace_path)
      ECOSYSTEMS.filter_map do |ecosystem_name, signals|
        match = signals.find { |file, _command| path.join(file).exist? }
        next unless match

        file, command = match
        { ecosystem: ecosystem_name, file: file, command: command }
      end
    end

    def intro
      <<~TXT.strip
        You are running a dependency security audit on this repository:
        detect which package manager(s) it uses, run the ecosystem-appropriate
        audit command for each one, and either report what you find or fix
        it — governed entirely by the dry run flag below.

        Dry run: {{dry_run}}
      TXT
    end

    def pre_scan_section
      return nil unless scan

      <<~TXT.strip
        ## Automated pre-scan results

        Syrus already scanned this checkout's lockfiles and grade tooling
        before invoking you — use these findings as your starting point
        rather than re-detecting from scratch. Verify against the real repo
        rather than trusting it blindly.

        - Detected ecosystems and audit commands: #{ecosystems_summary}
        - Configured graders (`.syrus.yml`): #{configured_graders_summary}
        - Auto-detected test/lint candidates: #{grade_signals_summary}
      TXT
    end

    def ecosystems_summary
      ecosystems = scan[:ecosystems]
      return "none detected — no recognized lockfile found" if ecosystems.empty?

      ecosystems.map { |e| "#{e[:ecosystem]} (`#{e[:command]}`, from `#{e[:file]}`)" }.join("; ")
    end

    def configured_graders_summary
      graders = scan[:configured_graders].graders
      return "none configured" if graders.empty?

      graders.map { |g| "#{g.name} (`#{g.command}`#{g.required ? "" : ", optional"})" }.join("; ")
    end

    def grade_signals_summary
      candidates = scan[:grade_signals].candidates
      return "none detected" if candidates.empty?

      candidates.map { |c| "#{c.name} (`#{c.run}`, evidence: #{c.evidence})" }.join("; ")
    end

    def step_by_step_instructions
      <<~INSTRUCTIONS.strip
        ## Step 1 — detect the package manager(s)

        Check for these lockfile/manifest signals, in this priority order
        within each ecosystem — this mirrors Syrus's own `prepare:`
        auto-detect (`RepoPrepPlan::AUTO_DETECT`), so the ecosystems you
        audit agree with what Syrus already installs. A repo can use more
        than one ecosystem at once (e.g. a Rails app with a Node-based
        frontend) — audit every ecosystem you find evidence for, not just
        the first:

        #{detection_table}

        If you find none of these files, stop and report that no recognized
        package manager was detected. Make no changes.

        ## Step 2 — run the audit command(s)

        For each detected ecosystem, run its audit command and read the
        output for known vulnerabilities. If the repo has more than one
        ecosystem, run all of them.

        ## Step 3 — no vulnerabilities found

        If every audit command reports a clean result, say so plainly and
        make no changes. That is a valid, successful outcome — it closes
        without a diff and without a PR.

        ## Step 4 — vulnerabilities found

        If dry run is `true`: do not edit any files and make no commit.
        Produce your findings as your final report instead — for each
        flagged dependency, state its name, current version, the patched
        version the audit tool recommends, and its severity if reported.

        If dry run is not `true`:

        - Bump each flagged dependency to the minimum version that resolves
          its advisory, using the ecosystem's own tooling (e.g. `bundle
          update <gem> --conservative`, `npm install <package>@<version>`,
          `yarn upgrade <package>@<version>`, `pnpm update <package>`) —
          never an indiscriminate `npm audit fix --force` or a blanket
          `bundle update` that could pull in unrelated, unreviewed changes.
          Only touch the dependencies the audit flagged.
        - Before committing, run this repository's own grade commands to
          confirm the bump doesn't break anything: #{grade_command_guidance}
        - If those commands pass, commit the dependency bump(s).
        - If any of them fail, do not commit. Revert your changes, leave the
          working tree exactly as you found it, and report which grade
          command failed and why instead of guessing at a further fix. That
          is a valid, successful outcome — it closes without a diff.
      INSTRUCTIONS
    end

    def detection_table
      ECOSYSTEMS.flat_map do |ecosystem_name, signals|
        signals.map { |file, command| "- #{ecosystem_name}: `#{file}` → `#{command}`" }
      end.join("\n")
    end

    def grade_command_guidance
      "prefer the graders already configured in this repo's `.syrus.yml` when present; " \
        "otherwise use the test/lint tooling this repo's own signals indicate " \
        "(the same detection `debug` and `onboard-to-syrus` use)."
    end
  end
end
