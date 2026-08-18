module Skills
  # Built-in skill (EPIC-234): reproduce a reported bug with a failing
  # automated test, root-cause it, then apply the minimal fix. Generic to
  # whatever test framework this repository already uses for grading —
  # reuses RepoGradePlan (graders already configured in `.syrus.yml`) and
  # RepoGradeSignals (the same auto-detection Skills::OnboardToSyrus uses)
  # instead of re-deriving test-framework detection a third time.
  #
  # Deliberately narrow scope, unlike OnboardToSyrus/Investigate: this
  # skill produces a real code diff, so its instructions spend real weight
  # discouraging unrelated improvements — the reported bug is the entire
  # brief. A failed reproduction is an explicit, valid outcome: the
  # instructions tell the agent to make no changes and report clearly
  # rather than guess at a fix for something it couldn't confirm, which
  # Steps::RunSkill's existing no_changes handling turns into a successful
  # Job close with no diff and no PR.
  class Debug < Base
    def self.skill_name
      "debug"
    end

    def self.description
      "Reproduces a reported bug with a failing test, root-causes it, and applies the minimal, scoped fix. " \
        "Reports clearly instead of guessing when it cannot reproduce the bug."
    end

    def self.parameter_schema
      [
        { key: "bug_description", type: "text", required: true, label: "Bug description" }
      ]
    end

    def to_s
      [ intro, pre_scan_section, step_by_step_instructions ].compact.join("\n\n")
    end

    private

    # Present only when a real on-disk checkout was available at
    # resolution time (Steps::RunSkill) — nil for every other resolution
    # path (picker, chat slash command, ScheduledTask fire), which fall
    # back to the generic detection table in step_by_step_instructions
    # with no concrete findings to report.
    def scan
      return nil unless @workspace_path

      @scan ||= {
        configured: RepoGradePlan.for(@workspace_path),
        signals: RepoGradeSignals.for(@workspace_path)
      }
    end

    def intro
      <<~TXT.strip
        You are debugging one specific reported bug in this repository:
        reproduce it with a failing automated test, find its root cause, then
        make the minimal fix that turns that test green. This is a bug fix,
        not a cleanup pass. Do not refactor, rename, reformat, or otherwise
        "improve" anything you notice along the way that isn't required to
        fix the reported bug, and do not add tests for anything beyond it.
        Scope is the reported bug only.

        Bug description: {{bug_description}}
      TXT
    end

    def pre_scan_section
      return nil unless scan

      <<~TXT.strip
        ## Automated pre-scan results

        Syrus already scanned this checkout's test tooling before invoking
        you — use it to pick the right test framework and command instead of
        guessing. This is the same detection Syrus's own grading and the
        `onboard-to-syrus` skill use, so it agrees with how this repository
        is actually validated. Verify against the real repo rather than
        trusting it blindly.

        - Configured graders (`.syrus.yml`): #{configured_graders_summary}
        - Auto-detected test/lint candidates: #{detected_candidates_summary}
      TXT
    end

    def configured_graders_summary
      graders = scan[:configured].graders
      return "none configured" if graders.empty?

      graders.map { |g| "#{g.name} (`#{g.command}`#{g.required ? "" : ", optional"})" }.join("; ")
    end

    def detected_candidates_summary
      candidates = scan[:signals].candidates
      return "none detected" if candidates.empty?

      candidates.map { |c| "#{c.name} (`#{c.run}`, evidence: #{c.evidence})" }.join("; ")
    end

    def step_by_step_instructions
      <<~INSTRUCTIONS.strip
        ## Step 1 — pick the test framework and reproduce

        Use the repository's own test framework — never introduce a new
        testing tool or an ad hoc reproduction script:

        - Prefer a configured grader from `.syrus.yml` whose command runs
          this repo's test suite (commonly named something like `rspec`,
          `jest`, `pytest`, `go-test`, or `tests`).
        - If none is configured, use the framework `onboard-to-syrus` would
          detect from the repo's own signals — the same table Syrus's own
          grading auto-detection uses:

        #{grade_detection_table}

        Write a new, minimal automated test that demonstrates the reported
        bug, in the location and style this repo's existing tests already
        use. Run it (scoped to just that test, where the framework supports
        it) and confirm it **fails for the reason described in the bug
        report** — not for an unrelated setup problem.

        If you cannot get a test to fail in a way that actually demonstrates
        the described bug after a genuine effort — the behavior doesn't
        reproduce, the repo doesn't behave as reported, or you can't isolate
        it in a test — **stop here**. Do not guess at a fix for a bug you
        could not confirm. Leave the working tree exactly as you found it
        (no commit, no partial test file left behind) and write a clear
        final report explaining what you tried and why it did not
        reproduce. That is a valid, successful outcome — it closes without
        a diff.

        ## Step 2 — find the root cause

        Once you have a reliably failing test, investigate the actual cause
        of the bug by reading the relevant code paths — don't guess from the
        symptom alone. Confirm your understanding explains exactly why the
        test you wrote fails.

        ## Step 3 — make the minimal fix

        Change only what's needed to fix the root cause you found. Do not:

        - refactor, rename, or reformat code you didn't have to touch
        - fix other bugs or code smells you notice along the way
        - add tests beyond the one reproducing this bug (plus, if this
          repo's convention calls for it, a test directly exercising the
          fixed code path)
        - expand scope beyond what the bug description asked for

        Run the failing test again and confirm it now passes, then run the
        broader relevant test suite (the same grader/command from Step 1) to
        check you haven't introduced a regression.

        ## Step 4 — commit

        Commit the failing test and the fix together (or as a small, clearly
        scoped sequence of commits). The result should be a repository where
        the new test passes and demonstrably would have failed before your
        fix.
      INSTRUCTIONS
    end

    def grade_detection_table
      RepoGradeSignals::RULE_DESCRIPTIONS.map do |rule|
        "- **#{rule.name}** (`#{rule.run}`) — #{rule.signals}"
      end.join("\n")
    end
  end
end
