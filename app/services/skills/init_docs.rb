module Skills
  # Built-in skill (EPIC-234): generates or refreshes a CLAUDE.md-equivalent
  # codebase overview (architecture, key directories, conventions) by
  # scanning repo structure — mirrors the harness's own `init` skill, but
  # runnable against any repo Syrus has been pointed at.
  #
  # Unlike Skills::OnboardToSyrus (which never touches an existing
  # `.syrus.yml` and produces a gap analysis instead), this skill is
  # expected to keep the doc current over time: an existing target file
  # gets refreshed, not just diagnosed. The risk that refresh path guards
  # against is clobbering anything a human already wrote into the doc. The
  # mechanism is a pair of HTML-comment markers
  # (`<!-- syrus:init-docs:preserve -->` / `<!-- syrus:init-docs:preserve:end -->`)
  # that the generated file itself seeds on first run (an "## Operator
  # notes" section) so there's always a documented, safe place for
  # human-authored content — and the instructions require the agent to
  # copy any such block verbatim into the refreshed file, never editing,
  # reformatting, or reordering what's inside it. Everything outside a
  # preserve block is "diff-and-propose": the agent re-scans the repo and
  # updates only what's actually stale relative to what the file already
  # says, rather than blindly regenerating the whole document every run.
  #
  # The Ruby-side pre-scan (present only when a real on-disk checkout is
  # available, i.e. Steps::RunSkill) does the marker extraction itself
  # rather than describing the convention and hoping the agent parses it
  # correctly — the exact preserved text is handed to the agent as data,
  # the same "pre-computed, not just described" pattern
  # Skills::OnboardToSyrus/Debug use for their own detection tables.
  class InitDocs < Base
    DEFAULT_TARGET_FILE = "CLAUDE.md"

    PRESERVE_START_TAG = "<!-- syrus:init-docs:preserve -->"
    PRESERVE_END_TAG = "<!-- syrus:init-docs:preserve:end -->"
    PRESERVE_BLOCK_PATTERN = /<!--\s*syrus:init-docs:preserve\s*-->.*?<!--\s*syrus:init-docs:preserve:end\s*-->/m

    NOISE_ENTRIES = %w[.git node_modules vendor tmp log .bundle coverage dist build .syrus .DS_Store].freeze

    def self.skill_name
      "init-docs"
    end

    def self.description
      "Generates or refreshes a CLAUDE.md-equivalent codebase overview (architecture, key directories, " \
        "conventions) by scanning repo structure. Detects and preserves any operator-authored sections " \
        "instead of overwriting the file wholesale."
    end

    def self.parameter_schema
      [
        { key: "target_file", type: "string", required: false, label: "Target doc file", default: DEFAULT_TARGET_FILE },
        { key: "dry_run", type: "boolean", required: false, label: "Dry run", default: false }
      ]
    end

    def to_s
      [ intro, pre_scan_section, step_by_step_instructions ].compact.join("\n\n")
    end

    private

    # Present only when a real on-disk checkout was available at
    # resolution time (Steps::RunSkill) — nil for every other resolution
    # path (picker, chat slash command, ScheduledTask fire), which fall
    # back to the generic step-by-step instructions with no concrete
    # findings to report.
    def scan
      return nil unless @workspace_path

      @scan ||= {
        existing_content: existing_content,
        preserved_sections: preserved_sections,
        top_level_entries: top_level_entries
      }
    end

    def target_file
      @args["target_file"].presence || DEFAULT_TARGET_FILE
    end

    def target_pathname
      Pathname.new(@workspace_path).join(target_file)
    end

    def existing_content
      return nil unless target_pathname.exist?

      target_pathname.read
    end

    def preserved_sections
      return [] unless existing_content

      existing_content.to_enum(:scan, PRESERVE_BLOCK_PATTERN).map { Regexp.last_match(0) }
    end

    def top_level_entries
      Pathname.new(@workspace_path).children
        .reject { |entry| NOISE_ENTRIES.include?(entry.basename.to_s) }
        .map { |entry| entry.basename.to_s }
        .sort
    end

    def intro
      <<~TXT.strip
        You are generating or refreshing this repository's codebase overview
        doc — a CLAUDE.md-equivalent file covering architecture, key
        directories, and conventions, scanned from the repo's own structure
        rather than invented. This mirrors the `init` skill this very agent
        environment uses on itself.

        Target file: {{target_file}}
        Dry run: {{dry_run}}
      TXT
    end

    def pre_scan_section
      return nil unless scan

      <<~TXT.strip
        ## Automated pre-scan results

        Syrus already scanned this checkout before invoking you — use this as
        your starting point rather than rediscovering everything from
        scratch. Verify against the real repo rather than trusting it
        blindly.

        - Target file (`#{target_file}`): #{existing_doc_summary}
        - Top-level entries: #{top_level_entries_summary}
        #{preserved_sections_summary}
      TXT
    end

    def existing_doc_summary
      if scan[:existing_content]
        "already exists. Refresh it (Step 3) — never edit a preserve-marked section."
      else
        "does not exist. Generate a new one from scratch (Step 2)."
      end
    end

    def top_level_entries_summary
      entries = scan[:top_level_entries]
      return "none found" if entries.empty?

      entries.map { |entry| "`#{entry}`" }.join(", ")
    end

    def preserved_sections_summary
      sections = scan[:preserved_sections]
      return "" if sections.empty?

      blocks = sections.each_with_index.map do |block, index|
        indented = block.gsub("\n", "\n  ")
        "  #{index + 1}.\n\n  ```\n  #{indented}\n  ```"
      end.join("\n\n")

      <<~TXT.rstrip
        - Preserve-marked section(s) found in the existing file — copy each one
          into the refreshed file verbatim, unchanged, at the same location it
          already occupies:

        #{blocks}
      TXT
    end

    def step_by_step_instructions
      <<~INSTRUCTIONS.strip
        ## Step 1 — check for an existing target file

        Look for `{{target_file}}` at the repository root (see the pre-scan
        result above for what Syrus already found).

        - If it **does not exist**, go to Step 2 and generate one from
          scratch.
        - If it **already exists**, go to Step 3 and refresh it instead of
          regenerating it wholesale.

        ## Step 2 — first-run generation

        Scan the repository's own structure to write the overview — do not
        invent architecture, directories, or conventions you can't back with
        something you actually found in the repo:

        - **Stack** — languages and frameworks in use, inferred from
          manifest/lockfiles (`Gemfile`, `package.json`, `go.mod`,
          `requirements.txt`, `Cargo.toml`, etc.) and top-level file
          extensions.
        - **Architecture in brief** — how the pieces fit together: main
          entry points, how a request/command flows through the code, any
          obvious layering.
        - **Key directories** — a short list or table of top-level
          directories (see the pre-scan's top-level entries) and what lives
          in each one.
        - **Conventions** — testing/build/lint commands actually defined in
          this repo (check `package.json` scripts, a `Makefile`, Rake
          tasks, CI workflow files under `.github/workflows/`), and any
          repo-specific rules you can find real evidence for. Do not
          fabricate a convention you can't point to.

        Near the end of the file, include an "## Operator notes" section
        wrapped in the preserve markers below, so operators have a
        documented, safe place to add content that this skill will never
        touch on a future refresh:

        ```
        ## Operator notes

        #{PRESERVE_START_TAG}
        (Add any team-authored notes here. Content between these two comment
        markers is preserved verbatim by the init-docs skill on every future
        refresh — the skill will never edit, reformat, or remove it.)
        #{PRESERVE_END_TAG}
        ```

        If dry run is `true`, do not create the file — write the drafted
        contents as your final report instead. Otherwise, write
        `{{target_file}}` at the repository root.

        ## Step 3 — refresh an existing target file

        Read the **entire** existing `{{target_file}}` first — do not start
        from a blank page.

        - Never edit, reformat, reorder, or remove anything between a
          `#{PRESERVE_START_TAG}` / `#{PRESERVE_END_TAG}` marker pair (the
          exact contents already extracted are in the pre-scan above). Copy
          each one verbatim into the refreshed file, at the same location it
          already occupies.
        - For everything else, re-scan the repository the same way as Step 2
          and compare your findings against what the file already says.
          Update only what's actually stale — a directory that's gone, a new
          top-level directory that's undocumented, a convention or command
          that's changed, a stack detail that's now wrong. Leave sections
          you confirm are still accurate untouched. This is a **refresh**,
          not a rewrite: don't regenerate prose that's already correct, and
          don't reorder or reformat sections just to match a preferred
          template.
        - If the existing file has no preserve-marked section yet, add the
          "## Operator notes" block from Step 2 so operators have a safe
          home for future edits — but don't otherwise restructure a file
          whose existing structure is already sound.
        - If your comparison finds nothing stale, say so plainly and make no
          changes. That is a valid, successful outcome.

        If dry run is `true`, do not write any changes — report exactly what
        you would update (and what you'd leave alone) instead.

        ## Step 4 — commit

        If dry run is not `true` and you wrote or changed the file, commit
        it. If dry run is `true`, or your refresh found nothing to change,
        make no commit — that always closes without a diff, which is the
        correct, successful outcome: it closes without opening a PR.
      INSTRUCTIONS
    end
  end
end
