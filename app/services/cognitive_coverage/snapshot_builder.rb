require_dependency "cognitive_coverage/snapshot"

module CognitiveCoverage
  class SnapshotBuilder
    DEFAULT_STALE_THRESHOLD_DAYS = 90
    HIGH_CHURN_THRESHOLD = 5
    HIGH_COMPLEXITY_THRESHOLD = 5
    LOW_TEST_COVERAGE_PCT = 60.0

    def self.call(...)
      new(...).call
    end

    def initialize(repository:, target_sha:, workspace_path: nil, line_facts: nil, engagements: nil,
      change_frequency: nil, coverage_snapshot: nil, target_health_records: nil,
      reliability_signals: {}, stale_threshold_days: DEFAULT_STALE_THRESHOLD_DAYS,
      generated_at: Time.current, git_runner: GitRunner.new)
      @repository = repository
      @target_sha = target_sha.to_s
      @workspace_path = workspace_path
      @line_facts = line_facts
      @engagements = engagements
      @change_frequency = change_frequency
      @coverage_snapshot = coverage_snapshot
      @target_health_records = target_health_records
      @reliability_signals = reliability_signals || {}
      @stale_threshold = stale_threshold_days.to_i.days
      @generated_at = generated_at
      @git_runner = git_runner
    end

    def call
      line_results = classify_lines
      files = rollups_for(line_results, :path)
      subsystems = rollups_for(line_results, :subsystem)
      repository_rollup = repository_rollup_for(line_results)

      Snapshot.new(
        repository: @repository,
        target_sha: @target_sha,
        generated_at: @generated_at,
        line_results: line_results,
        files: files,
        subsystems: subsystems,
        repository_rollup: repository_rollup,
        ranked_items: ranked_items(files, subsystems, repository_rollup)
      )
    end

    private

    def classify_lines
      projected = projected_engagements.group_by(&:path)

      facts.map do |fact|
        engagement = best_engagement_for(fact, projected[fact.path] || [])
        state = state_for(fact, engagement)

        LineResult.new(
          path: fact.path,
          line_number: fact.line_number,
          state: state,
          last_modified_at: fact.last_modified_at,
          engaged_at: engagement&.engaged_at,
          source: engagement&.source,
          complexity: fact.complexity.to_i
        )
      end
    end

    def facts
      @facts ||= Array(@line_facts || git_line_facts).sort_by { |fact| [ fact.path, fact.line_number.to_i ] }
    end

    def git_line_facts
      return [] unless @workspace_path.present?

      GitLineFacts.for(workspace_path: @workspace_path, target_sha: @target_sha, git_runner: @git_runner)
    end

    def projected_engagements
      @projected_engagements ||= source_engagements.filter_map { |engagement| projector.project(engagement) }
    end

    def source_engagements
      @source_engagements ||= Array(@engagements || EngagementEvents.for(@repository))
    end

    def projector
      @projector ||= LineProjector.new(workspace_path: @workspace_path, target_sha: @target_sha, git_runner: @git_runner)
    end

    def best_engagement_for(fact, engagements)
      engagements
        .select { |engagement| engagement.line_number.blank? || engagement.line_number.to_i == fact.line_number.to_i }
        .max_by(&:engaged_at)
    end

    def state_for(fact, engagement)
      return "blind" unless engagement
      return "stale" if fact.last_modified_at && engagement.engaged_at < fact.last_modified_at
      return "stale" if engagement.engaged_at < @generated_at - @stale_threshold

      "covered"
    end

    def rollups_for(line_results, key_method)
      line_results
        .group_by { |line| rollup_key(line, key_method) }
        .transform_values { |lines| build_rollup(lines.first.then { |line| rollup_key(line, key_method) }, lines) }
    end

    def repository_rollup_for(line_results)
      key = @repository ? "#{@repository.owner}/#{@repository.name}" : "repository"
      build_rollup(key, line_results)
    end

    def build_rollup(key, lines)
      counts = lines.group_by(&:state).transform_values(&:count)
      Rollup.new(
        key: key,
        line_count: lines.count,
        covered_count: counts.fetch("covered", 0),
        stale_count: counts.fetch("stale", 0),
        blind_count: counts.fetch("blind", 0),
        risk_score: risk_score_for(key, lines, counts),
        explanations: explanations_for(key, lines, counts)
      )
    end

    def ranked_items(files, subsystems, repository_rollup)
      file_items = files.values.map { |rollup| ranked_item("file", rollup) }
      subsystem_items = subsystems.values.map { |rollup| ranked_item("subsystem", rollup) }
      repository_item = ranked_item("repository", repository_rollup)

      [ *file_items, *subsystem_items, repository_item ].sort_by { |item| [ -item.risk_score, item.kind, item.key ] }
    end

    def ranked_item(kind, rollup)
      RankedItem.new(
        key: rollup.key,
        kind: kind,
        risk_score: rollup.risk_score,
        coverage_state: dominant_state(rollup),
        explanations: rollup.explanations,
        rollup: rollup,
        signals: signals_for(rollup.key)
      )
    end

    def risk_score_for(key, lines, counts)
      line_count = lines.count.nonzero? || 1
      score = counts.fetch("blind", 0).fdiv(line_count) * 60.0
      score += counts.fetch("stale", 0).fdiv(line_count) * 35.0
      score += churn_for(key) >= HIGH_CHURN_THRESHOLD ? 20.0 : churn_for(key) * 2.0
      score += coverage_risk_for(key)
      score += lines.sum(&:complexity).to_i >= HIGH_COMPLEXITY_THRESHOLD ? 15.0 : 0.0
      score += unhealthy_target_health? ? 15.0 : 0.0
      score += old_blind_bonus(lines)
      score += reliability_score_for(key)
      score.round(2)
    end

    def explanations_for(key, lines, counts)
      explanations = [ coverage_explanation(lines, counts) ]
      explanations << "high churn" if churn_for(key) >= HIGH_CHURN_THRESHOLD
      explanations << test_coverage_explanation(key)
      explanations << "high complexity" if lines.sum(&:complexity).to_i >= HIGH_COMPLEXITY_THRESHOLD
      explanations << "unhealthy target" if unhealthy_target_health?
      explanations << "old blind code" if old_blind_bonus(lines).positive?
      explanations << "recent reliability signal" if reliability_score_for(key).positive?
      explanations.compact
    end

    def coverage_explanation(lines, counts)
      line_count = lines.count.nonzero? || 1
      blind_ratio = counts.fetch("blind", 0).fdiv(line_count)
      stale_ratio = counts.fetch("stale", 0).fdiv(line_count)

      return "blind" if blind_ratio >= 0.5
      return "stale" if stale_ratio >= 0.5
      return "partially blind" if blind_ratio.positive?
      return "partially stale" if stale_ratio.positive?

      "covered"
    end

    def dominant_state(rollup)
      {
        "blind" => rollup.blind_count,
        "stale" => rollup.stale_count,
        "covered" => rollup.covered_count
      }.max_by { |state, count| [ count, state == "blind" ? 2 : state == "stale" ? 1 : 0 ] }.first
    end

    def rollup_key(line, key_method)
      key_method == :subsystem ? subsystem_for(line.path) : line.path
    end

    def subsystem_for(path)
      parts = path.to_s.split("/")
      parts.length <= 1 ? "." : parts.first
    end

    def churn_for(key)
      frequency = @change_frequency || {}
      return frequency[key].to_i if frequency.key?(key)

      prefix = key == "." ? "" : "#{key}/"
      frequency.sum { |path, count| path.to_s.start_with?(prefix) ? count.to_i : 0 }
    end

    def coverage_risk_for(key)
      pct = test_coverage_pct_for(key)
      return 20.0 if pct.nil?
      return 20.0 if pct <= 0.0
      return 12.0 if pct < LOW_TEST_COVERAGE_PCT

      0.0
    end

    def test_coverage_explanation(key)
      pct = test_coverage_pct_for(key)
      return "untested" if pct.nil? || pct <= 0.0
      return "low test coverage" if pct < LOW_TEST_COVERAGE_PCT

      nil
    end

    def test_coverage_pct_for(key)
      stats = coverage_files[key]
      return stats["lines_pct"].to_f if stats&.key?("lines_pct") && !stats["lines_pct"].nil?

      matching = coverage_files.select { |path, _stats| path.to_s.start_with?("#{key}/") }
      return nil if matching.empty?

      values = matching.values.filter_map { |stats| stats["lines_pct"] }
      values.empty? ? nil : values.sum(&:to_f).fdiv(values.count)
    end

    def coverage_files
      @coverage_files ||= latest_coverage_snapshot&.data || {}
    end

    def latest_coverage_snapshot
      @latest_coverage_snapshot ||= @coverage_snapshot ||
        CoverageSnapshot.on_default_branch.where(repository: @repository).order(created_at: :desc).first
    end

    def unhealthy_target_health?
      target_health.any?(&:unhealthy?)
    end

    def target_health
      @target_health ||= Array(@target_health_records || TargetHealthRecord.where(repository: @repository, commit_sha: @target_sha).latest_first)
    end

    def old_blind_bonus(lines)
      oldest_blind = lines.select { |line| line.state == "blind" }.filter_map(&:last_modified_at).min
      return 0.0 unless oldest_blind && oldest_blind < @generated_at - @stale_threshold

      8.0
    end

    def reliability_score_for(key)
      value = @reliability_signals[key] || @reliability_signals[key.to_s]
      value.to_f.positive? ? 10.0 : 0.0
    end

    def signals_for(key)
      {
        churn: churn_for(key),
        test_coverage_pct: test_coverage_pct_for(key),
        unhealthy_target: unhealthy_target_health?,
        reliability: @reliability_signals[key] || @reliability_signals[key.to_s]
      }
    end
  end
end
