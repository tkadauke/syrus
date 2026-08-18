module Skills
  # Built-in skill (EPIC-234): summarizes merged PRs since the last tag (or
  # an explicit `since` ref) into a changelog entry, reading git/PR history
  # only — no GitHub API call, mirroring Skills::ExplainFailingCi's note
  # that the agent sandbox has no GitHub API credentials of its own. What
  # looks like "PR history" is entirely recoverable from `git log`: GitHub's
  # default squash-merge leaves `<PR title> (#123)` as the commit subject on
  # the base branch, and a non-squash merge leaves a `Merge pull request
  # #123 from ...` commit with the PR's own description in its body — both
  # patterns are just git commit metadata, walked with `--first-parent` so
  # individual commits already summarized by a merge commit aren't also
  # listed as separate entries.
  #
  # No repo-specific format assumption is baked in beyond a generic Keep a
  # Changelog-style default (`## [Unreleased]` + `### Added/Changed/Fixed/
  # Removed` subsections) — an operator wanting a different structure
  # overrides `format` per invocation rather than needing a repo-local
  # skill, the same reasoning Skills::LicenseAudit's `denied_licenses`
  # documents for staying built-in instead of borderline.
  #
  # Unlike Skills::DependencyAudit/LicenseAudit (which describe their audit
  # commands and leave running them to the agent, since the result isn't
  # statically readable), the PR history here IS fully recoverable from a
  # plain, read-only `git log` — so the Ruby-side pre-scan runs it directly
  # via GitRunner and hands the agent a concrete candidate list, the same
  # "real finding, not a description" reasoning Skills::LicenseAudit's
  # node_modules pre-scan documents. A git failure (bad `since` ref, no
  # tags, not a git checkout) degrades to a plain nil/empty result — the
  # step-by-step instructions below always work even with no pre-scan data.
  #
  # `dry_run` (boolean, default false) governs the entire write/report
  # split, the same switch as Skills::InitDocs/Skills::OnboardToSyrus: a
  # false default because drafting a changelog entry and opening a PR is
  # low-risk, reversible-by-review work, not a risky bulk mutation like
  # Skills::DependencyAudit's version bumps (which default dry_run true).
  class ChangelogGenerate < Base
    CHANGELOG_FILENAMES = %w[CHANGELOG.md CHANGELOG.markdown CHANGELOG CHANGES.md HISTORY.md].freeze
    DEFAULT_TARGET_FILE = "CHANGELOG.md"

    SQUASH_PR_SUFFIX_PATTERN = /\(#(\d+)\)\s*\z/
    MERGE_COMMIT_PATTERN = /\AMerge pull request #(\d+) from\s/

    ENTRY_DISPLAY_LIMIT = 50

    DEFAULT_FORMAT = <<~FORMAT.strip
      Keep a Changelog style: a `## [Unreleased]` heading at the top of the
      file (below the `# Changelog` title, if present), with `### Added` /
      `### Changed` / `### Fixed` / `### Removed` subsections as needed —
      omit any subsection that has no entries. Each entry is one bullet
      line summarizing a single merged PR, ending with its PR reference
      (e.g. `(#123)`) when a PR number was found.
    FORMAT

    def self.skill_name
      "changelog-generate"
    end

    def self.description
      "Summarizes merged PRs since the last tag (or a since parameter) into a changelog entry, " \
        "reading git/PR history only. Opens a PR updating the changelog, or reports the draft only if dry_run is set."
    end

    def self.parameter_schema
      [
        { key: "since", type: "string", required: false,
          label: "Since (tag, ref, or date — optional, defaults to the last git tag)" },
        { key: "format", type: "text", required: false, label: "Changelog format", default: DEFAULT_FORMAT },
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
        existing_changelog: existing_changelog_filename,
        since: since_value,
        since_source: since_source,
        entries: candidate_entries
      }
    end

    def existing_changelog_filename
      path = Pathname.new(@workspace_path)
      CHANGELOG_FILENAMES.find { |name| path.join(name).file? }
    end

    def since_param
      @args["since"].presence
    end

    def git
      @git ||= GitRunner.new
    end

    def since_value
      return @since_value if defined?(@since_value)

      @since_value = since_param || last_tag
    end

    def since_source
      if since_param
        "given `since` parameter"
      elsif since_value
        "auto-detected last tag"
      else
        "no tags found — using full history"
      end
    end

    def last_tag
      git.run("describe", "--tags", "--abbrev=0", chdir: @workspace_path).strip.presence
    rescue GitRunner::GitError
      nil
    end

    # Walked with --first-parent so individual commits already summarized
    # by a merge commit on a feature branch aren't also listed on their
    # own — a squash-merged repo has no merge commits at all, so every
    # commit on the mainline is still seen exactly once either way.
    # Returns nil when git log itself could not run (bad `since` ref, not
    # a git checkout); [] is the distinct "ran fine, nothing found" case.
    def candidate_entries
      return @candidate_entries if defined?(@candidate_entries)

      args = [ "log", "--first-parent" ]
      args << "#{since_value}..HEAD" if since_value.present?
      args << "--pretty=format:%H%x09%s%x09%b%x00"

      output = git.run(*args, chdir: @workspace_path)
      records = output.split("\x00").map(&:strip).reject(&:empty?)
      @candidate_entries = records.map { |record| parse_record(record) }
    rescue GitRunner::GitError
      @candidate_entries = nil
    end

    def parse_record(record)
      sha, subject, body = record.split("\t", 3)
      short_sha = sha.to_s.first(10)

      if (match = subject.match(SQUASH_PR_SUFFIX_PATTERN))
        { sha: short_sha, pr_number: match[1], summary: subject.sub(SQUASH_PR_SUFFIX_PATTERN, "").strip }
      elsif (match = subject.match(MERGE_COMMIT_PATTERN))
        { sha: short_sha, pr_number: match[1], summary: body_summary(body) || subject }
      else
        { sha: short_sha, pr_number: nil, summary: subject.to_s.strip }
      end
    end

    def body_summary(body)
      body.to_s.lines.map(&:strip).find(&:present?)
    end

    def intro
      <<~TXT.strip
        You are drafting a changelog entry for the merged pull requests
        (or, on repos that don't use PRs, the merged/landed commits) since
        the given starting point, reading git and PR history only — do not
        call the GitHub API or any other external service; this sandbox
        has no GitHub API credentials of its own, only local git access.

        Since: {{since}}
        Format: {{format}}
        Dry run: {{dry_run}}
      TXT
    end

    def pre_scan_section
      return nil unless scan

      <<~TXT.strip
        ## Automated pre-scan results

        Syrus already inspected this checkout's changelog file and git
        history before invoking you — use these findings as your starting
        point rather than re-detecting from scratch. Verify against the
        real repo rather than trusting it blindly, especially for any
        commit summary derived from a merge commit body.

        - Existing changelog file: #{existing_changelog_summary}
        - Starting point (`since`): #{since_summary}
        - Candidates found via `git log --first-parent`: #{entries_summary}
      TXT
    end

    def existing_changelog_summary
      if scan[:existing_changelog]
        "`#{scan[:existing_changelog]}` already exists. Update it in place (Step 4) — never rewrite its existing entries."
      else
        "none found (checked #{CHANGELOG_FILENAMES.map { |name| "`#{name}`" }.join(', ')}). " \
          "Create `#{DEFAULT_TARGET_FILE}` from scratch (Step 4)."
      end
    end

    def since_summary
      scan[:since] ? "`#{scan[:since]}` (#{scan[:since_source]})" : scan[:since_source]
    end

    def entries_summary
      entries = scan[:entries]
      return "could not run `git log` in this checkout — fall back to Step 1/2 below and investigate yourself." if entries.nil?
      return "none found — nothing has landed since the starting point." if entries.empty?

      shown = entries.first(ENTRY_DISPLAY_LIMIT)
      lines = shown.map { |e| "  - #{entry_label(e)}: #{e[:summary]}" }.join("\n")
      remainder = entries.size - shown.size
      truncated = remainder.positive? ? "\n  - ...and #{remainder} more, not shown here — read the rest of the git log yourself." : ""
      "#{entries.size} candidate(s) found:\n#{lines}#{truncated}"
    end

    def entry_label(entry)
      entry[:pr_number] ? "PR ##{entry[:pr_number]}" : "commit `#{entry[:sha]}` (no PR reference found)"
    end

    def step_by_step_instructions
      <<~INSTRUCTIONS.strip
        ## Step 1 — resolve the starting point

        If `{{since}}` is set, use it verbatim as the git starting point —
        it may be a tag, a branch/commit ref, or a date understood by
        `git log --since=`.

        If `{{since}}` is not set, find the most recent tag reachable from
        the current branch with `git describe --tags --abbrev=0`. If that
        command fails (the repository has no tags yet), treat the entire
        history up to the current commit as in scope, and say so plainly
        in your report — this is the repo's first changelog entry, not an
        error. (Syrus already resolved this for you above; verify it
        rather than blindly redoing the work.)

        ## Step 2 — gather merged PR history from git log

        The pre-scan above already ran `git log --first-parent
        <since>..HEAD` and classified each commit into a merged-PR or
        direct-commit candidate. If the pre-scan is unavailable (see
        above), reproduce it yourself: run that same command and read
        every commit subject for evidence of a merged PR. Two patterns
        cover the vast majority of GitHub repositories — a repo may use
        either or a mix:

        - **Squash merge** (GitHub's default): the commit subject already
          ends with the original PR's title suffixed `(#123)` — the
          subject itself IS the PR title.
        - **Merge commit**: a commit whose subject reads `Merge pull
          request #123 from <branch>` — the summary is the first line of
          that merge commit's body (or, if the body is empty, the
          subject itself).

        A commit with neither pattern is a direct, un-PR'd commit to the
        base branch — summarize it as its own entry, just without a PR
        reference.

        For every pre-scanned candidate, verify its summary against the
        real commit (`git show <sha>` or the PR body) before using it —
        the pre-scan is a starting point, not ground truth.

        ## Step 3 — write the entries

        For every PR/commit found, write one concise, user-facing bullet —
        summarize the *effect* of the change, not the literal commit
        message, when the two differ (a commit titled `fix bug` should
        become something like "Fixed a crash when ..." if the commit body
        or diff makes the actual effect clear; when it's genuinely unclear,
        keep the original title rather than guessing). Group entries under
        Added / Changed / Fixed / Removed by reading each change's intent —
        prefer an explicit conventional-commit-style prefix (`feat:`,
        `fix:`, `chore:`, etc.) when the repo's commits actually use one,
        otherwise use your own judgment. Do not invent a category system
        beyond these four buckets unless `{{format}}` explicitly asks for
        one.

        Do not fabricate a PR number or a change that didn't happen — only
        write what's evidenced by the git log you actually read. If you
        find zero merged PRs/commits since the starting point, say so
        plainly and make no changes. That is a valid, successful outcome —
        it closes without a diff and without a PR.

        ## Step 4 — apply the format and update the changelog file

        Format: {{format}}

        - If the changelog file already exists (see the pre-scan above),
          insert the new entry section at the top of the file's existing
          entry history — immediately below the file's own title/intro if
          it has one, otherwise at the very top. Never edit, reorder, or
          remove any existing entry.
        - If it doesn't exist yet, create `#{DEFAULT_TARGET_FILE}` with a
          `# Changelog` title followed by the new entry section.

        ## Step 5 — dry run vs. write

        If dry run is `true`: do not create or edit any file. Write the
        drafted changelog entry (exactly as you would have written it to
        the file) as your final report instead. Make no commit — this
        always closes without a diff and without a PR.

        If dry run is not `true`: write the change to the changelog file
        and commit it.
      INSTRUCTIONS
    end
  end
end
