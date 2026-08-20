module Skills
  # Built-in skill (EPIC-234): identifies unused files, exports, and
  # routes via static analysis appropriate to the detected language(s),
  # then either reports the findings (dry run, the default) or removes
  # only the unambiguous ones and commits.
  #
  # Dead-code detection has a real false-positive risk — dynamic
  # dispatch, metaprogramming, reflection (`constantize`, `send`), and
  # framework convention-over-configuration wiring (Rails autoloading,
  # route helpers, JS barrel re-exports) all look "unreferenced" to a
  # naive static scan while being very much alive. So unlike
  # Skills::DependencyAudit (where a clean/flagged verdict from an audit
  # tool is authoritative), this skill's instructions require the agent
  # to state its confidence and reasoning for every single finding
  # instead of asserting certainty — "no static references found; verify
  # before removing" rather than "this is dead code."
  #
  # `apply_fixes` (boolean, default false) gates whether this skill ever
  # produces a diff at all. When false, the skill always ends via
  # Steps::RunSkill's no_changes path regardless of what it finds — a
  # findings report is not itself a code change. When true, it may still
  # end with no changes (nothing unambiguous enough to remove) — the
  # report-only behavior is the floor, not something apply_fixes ever
  # narrows.
  class DeadCodeSweep < Base
    LANGUAGE_TOOLS = [
      {
        language: "Ruby",
        signal: "Gemfile",
        tools: [
          "`bundle exec rubocop --only Lint/UnusedMethodArgument,Lint/UselessAssignment,Lint/UnusedBlockArgument` for local unused-variable smells",
          "manual cross-reference: Ruby has no reliable single unused-file/const/route detector, so grep the whole repo for each candidate's file basename, class/module/constant name, and (for routes) its path and route helper name"
        ]
      },
      {
        language: "JavaScript/TypeScript",
        signal: "package.json",
        tools: [
          "`npx knip` or `npx ts-prune` if either is already part of this repo's toolchain — do not add a new dependency just to run one audit",
          "`npx eslint . --rule '{\"no-unused-vars\":\"error\",\"@typescript-eslint/no-unused-vars\":\"error\"}'` for unused local bindings and imports"
        ]
      },
      {
        language: "Go",
        signal: "go.mod",
        tools: [
          "`go vet ./...` for basic issues",
          "`staticcheck ./...` (checks unused code) if it's already available in this repo's toolchain"
        ]
      }
    ].freeze

    def self.skill_name
      "dead-code-sweep"
    end

    def self.description
      "Identifies unused files, exports, and routes via language-appropriate static analysis, reporting " \
        "each finding with its own confidence and reasoning. Report-only by default; can optionally remove " \
        "only the unambiguous findings and commit."
    end

    def self.parameter_schema
      [
        { key: "apply_fixes", type: "boolean", required: false, label: "Apply fixes", default: false }
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

      @scan ||= { languages: detected_languages }
    end

    def detected_languages
      path = Pathname.new(@workspace_path)
      LANGUAGE_TOOLS.select { |entry| path.join(entry[:signal]).exist? }
    end

    def intro
      <<~TXT.strip
        You are running a dead-code sweep on this repository: identify
        unused files, exports, and routes using static analysis
        appropriate to the language(s) this repo actually uses, then
        either report what you find or remove only the unambiguous cases
        — governed entirely by the apply fixes flag below.

        Dead-code detection has a real false-positive risk: dynamic
        dispatch, metaprogramming, reflection, and framework
        convention-over-configuration wiring can all look unreferenced to
        a naive scan while being very much alive. Never assert that a
        finding definitely is dead code — for every finding, state your
        confidence (high/medium/low) and the reasoning behind it, and
        note what you checked (and didn't check) to reach that
        confidence.

        Apply fixes: {{apply_fixes}}
      TXT
    end

    def pre_scan_section
      return nil unless scan

      <<~TXT.strip
        ## Automated pre-scan results

        Syrus already scanned this checkout for language signals before
        invoking you — use this as your starting point for which
        ecosystem-appropriate tools to run, not as a substitute for
        actually running them.

        - Detected languages: #{languages_summary}
      TXT
    end

    def languages_summary
      languages = scan[:languages]
      return "none detected — no recognized language signal found" if languages.empty?

      languages.map { |l| "#{l[:language]} (from `#{l[:signal]}`)" }.join("; ")
    end

    def step_by_step_instructions
      <<~INSTRUCTIONS.strip
        ## Step 1 — detect the language(s)

        Check for these signals — a repo can use more than one language
        at once (e.g. a Rails app with a Node-based frontend), and this
        very repo does. Run the appropriate tooling for every language
        you find evidence for, not just the first:

        #{detection_table}

        If you find none of these signals, fall back to a manual,
        repo-wide cross-reference sweep (Step 2) using whatever source
        layout the repo actually has.

        ## Step 2 — run static analysis, then verify each candidate manually

        For each detected language, run its appropriate tool(s) from the
        table above where available in this repo's existing toolchain.
        Automated tools give you *candidates*, not verdicts — they can't
        see dynamic dispatch, string-based reflection (Ruby
        `constantize`/`send`, JS dynamic `import()`), test-only usage, or
        config/view-only references. For every candidate a tool flags —
        and for every file/export/route you additionally suspect is
        unused from your own reading of the repo — verify it yourself:

        - grep the whole repository (including tests, config, views/
          templates, CI workflow files, and docs) for the file's
          basename, its exported symbol/class/module/constant name, and,
          for a route, both its path and its route helper name
        - check whether it's reachable through metaprogramming, reflection,
          or a registry/lookup table (a `Registry`-style array, a
          `case`/`when` dispatch, a dynamically-built require) before
          concluding it's unreferenced
        - note explicitly what you checked, so your confidence rating is
          backed by something concrete rather than "the tool said so"

        ## Step 3 — build the findings report

        For every finding, report:

        - what it is (file path, export/symbol name, or route) and where
        - your confidence: high / medium / low
        - your reasoning — what you checked, and why it does or doesn't
          rule out a use you can't see statically

        Do not present findings as certainties. A finding with any
        plausible dynamic or reflective use should be reported at medium
        or low confidence with that caveat spelled out, not omitted or
        asserted as dead.

        If you find nothing, say so plainly. That is a valid, successful
        outcome.

        ## Step 4 — apply fixes flag

        If apply fixes is not `true`: stop here. Do not edit, delete, or
        commit anything, no matter how confident you are in a finding.
        Your final report (Step 3) is the entire output. This always
        closes without a diff — a findings-only report is a valid,
        successful outcome even when you found real dead code.

        If apply fixes is `true`: from your findings, remove only the
        **unambiguous** ones — specifically, a file with literally zero
        inbound references anywhere in the repository (no grep hit for
        its basename, its exported class/module/constant name, or any
        route path/helper it defines, in any other file, including
        tests, config, CI workflow files, and docs). Leave every other
        finding untouched, no matter how confident you are, and still
        include it in your final report as something a human should
        review. Do not remove individual exports, individual routes, or
        anything inside a file that's still referenced elsewhere — only
        whole files with zero inbound references qualify as unambiguous
        for this skill.

        After removing the unambiguous files, run this repository's own
        grade commands (prefer the graders already configured in this
        repo's `.syrus.yml`; otherwise use the test/lint tooling this
        repo's own signals indicate) to confirm nothing broke. If they
        pass, commit the removal(s). If any of them fail, do not commit
        — revert your changes, leave the working tree exactly as you
        found it, and report which grade command failed and why instead
        of guessing at a further fix. That is a valid, successful
        outcome — it closes without a diff.
      INSTRUCTIONS
    end

    def detection_table
      LANGUAGE_TOOLS.map do |entry|
        tools = entry[:tools].map { |t| "  - #{t}" }.join("\n")
        "- #{entry[:language]} (signal: `#{entry[:signal]}`):\n#{tools}"
      end.join("\n")
    end
  end
end
