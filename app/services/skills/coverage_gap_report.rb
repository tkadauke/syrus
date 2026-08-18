module Skills
  # Built-in skill (EPIC-234): read-only report ranking files/modules by
  # test-coverage risk — weighted by recent change frequency (git log)
  # rather than raw coverage percentage alone, since a stable low-coverage
  # file is lower priority than a frequently-changed one. Report-only, no
  # diff: like Skills::ExplainFailingCi/Investigate, a successful run
  # writes its findings and commits nothing, which Steps::RunSkill's
  # no_changes handling turns into a successful Job close with no PR.
  #
  # Reuses the same coverage data source the `coverage_analyze` Step
  # writes into (CoverageSnapshot, per-file `data`) instead of re-deriving
  # coverage numbers — see Steps::CoverageAnalyze#upsert_snapshot. The
  # actual ranking (coverage x change frequency) is computed Ruby-side via
  # CoverageAnalysis::ChangeFrequency + CoverageAnalysis::RiskRanking,
  # mirroring why Skills::ExplainFailingCi pre-fetches CI data server-side:
  # the agent sandbox has no direct read access to the CoverageSnapshot
  # model, only to files on disk, so the ranking has to be computed here
  # and handed to the agent as a pre-computed table.
  #
  # That pre-compute only happens when both a repository (to look up the
  # latest CoverageSnapshot) and a real on-disk workspace (to run `git
  # log` for change frequency) are available — currently only
  # Steps::RunSkill supplies both. Other resolution paths (picker, chat
  # slash command, ScheduledTask fire) fall back to generic instructions
  # with no pre-computed ranking, the same existing limitation
  # Skills::OnboardToSyrus/Debug already have.
  class CoverageGapReport < Base
    DEFAULT_LOOKBACK_DAYS = CoverageAnalysis::ChangeFrequency::DEFAULT_LOOKBACK_DAYS
    REPORT_LIMIT = 25

    def self.skill_name
      "coverage-gap-report"
    end

    def self.description
      "Read-only report ranking files by test-coverage risk, weighted by recent change frequency rather than raw coverage percentage alone. Makes no changes."
    end

    def self.parameter_schema
      [
        { key: "lookback_days", type: "integer", required: false,
          label: "Change-frequency lookback (days)", default: DEFAULT_LOOKBACK_DAYS }
      ]
    end

    def to_s
      [ intro, ranking_section, step_by_step_instructions ].compact.join("\n\n")
    end

    private

    def lookback_days
      value = Integer(@args["lookback_days"])
      value.positive? ? value : DEFAULT_LOOKBACK_DAYS
    rescue ArgumentError, TypeError
      DEFAULT_LOOKBACK_DAYS
    end

    def snapshot
      return nil unless @repository

      @snapshot ||= CoverageSnapshot.on_default_branch
        .where(repository: @repository)
        .order(created_at: :desc)
        .first
    end

    def ranked_files
      return nil unless snapshot && @workspace_path

      @ranked_files ||= begin
        change_frequency = CoverageAnalysis::ChangeFrequency.for(@workspace_path, lookback_days: lookback_days)
        CoverageAnalysis::RiskRanking.rank(files: snapshot.data, change_frequency: change_frequency, limit: REPORT_LIMIT)
      end
    end

    def intro
      <<~TXT.strip
        You are producing a read-only coverage-gap report for this
        repository: which files carry the highest test-coverage risk right
        now, ranked by a combination of low coverage and how often the
        file has recently changed — not raw coverage percentage alone. A
        stable file with low coverage is lower priority than a file with
        the same coverage under active churn, because churn is where
        untested regressions actually get introduced.

        This is a report, not an implementation task: do not write or fix
        any tests yourself, do not edit any other files, and make no
        commit. Your job is to write the report as your final output.

        Change-frequency lookback window: {{lookback_days}} days.
      TXT
    end

    def ranking_section
      return nil unless @repository && @workspace_path

      <<~TXT.strip
        ## Automated pre-computed ranking

        Syrus already computed this ranking before invoking you — reusing
        the same per-file coverage data the `coverage_analyze` Step
        records (`CoverageSnapshot`) plus recent git commit counts per
        file over the lookback window above. Present it as your starting
        point; do not recompute coverage or change frequency yourself
        unless you have a specific, stated reason to doubt an entry.

        #{ranking_body}
      TXT
    end

    def ranking_body
      return "No coverage data is available for this repository yet (no CoverageSnapshot recorded on the default branch). " \
        "Report that coverage data is unavailable and stop — do not attempt to generate coverage yourself." unless snapshot

      return "The most recent coverage snapshot (#{snapshot.branch}, captured #{snapshot.created_at.utc.iso8601}) has no per-file data recorded. " \
        "Report that and stop." if ranked_files.blank?

      <<~TXT.strip
        Source: CoverageSnapshot on `#{snapshot.branch}`, captured #{snapshot.created_at.utc.iso8601} (sha #{snapshot.sha}).

        Rank | File | Coverage (lines) | Recent changes | Risk score
        --- | --- | --- | --- | ---
        #{ranking_table}
      TXT
    end

    def ranking_table
      ranked_files.each_with_index.map do |f, index|
        coverage = f.lines_pct.nil? ? "no data" : "#{f.lines_pct}%"
        "#{index + 1} | `#{f.path}` | #{coverage} | #{f.change_count} | #{f.risk_score}"
      end.join("\n")
    end

    def step_by_step_instructions
      <<~TXT.strip
        ## What to do

        Using the pre-computed ranking above (or, if it is unavailable,
        your own read-only inspection of the repository's coverage
        tooling and `git log` history), write a clear report for an
        operator:

        - List the highest-risk files, with their coverage percentage,
          recent change count, and a one-line note on why each one
          matters (e.g. "core payment path, touched in 8 of the last
          #{lookback_days} days, 12% line coverage").
        - Group or call out files that share an obvious risk theme (a
          whole under-tested module, a hot path with no tests at all)
          rather than only listing bare filenames.
        - If nothing meets a reasonable risk bar (coverage is broadly
          healthy, or nothing risky has changed recently), say so plainly
          — that is a valid, successful outcome.

        Do not open, edit, or create any files. Do not write tests. Do not
        commit anything — this skill always ends with no diff, which is
        the correct, successful outcome: it closes without opening a PR.
        Write the report as your final message.
      TXT
    end
  end
end
