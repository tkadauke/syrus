module App
  class CognitiveDebtPayload
    REVIEW_QUEUE_LIMIT = 8
    CHURN_LOOKBACK = 90.days

    def self.for(repository:)
      new(repository: repository).to_h
    end

    def initialize(repository:)
      @repository = repository
    end

    def to_h
      snapshot = CognitiveCoverage::SnapshotBuilder.call(
        repository: repository,
        target_sha: target_sha,
        line_facts: line_facts,
        coverage_snapshot: latest_coverage_snapshot,
        change_frequency: change_frequency,
        target_health_records: target_health_records,
        generated_at: Time.current
      )

      {
        generated_at: snapshot.generated_at.iso8601,
        target_sha: target_sha,
        proxy_notice: "Cognitive coverage is a proxy for human engagement, not guaranteed understanding.",
        summary: rollup_json(snapshot.repository_rollup),
        subsystems: snapshot.subsystems.values.sort_by { |rollup| rollup.key }.map { |rollup| rollup_json(rollup) },
        files: snapshot.files.values.sort_by { |rollup| rollup.key }.map { |rollup| rollup_json(rollup) },
        review_queue: review_queue_json(snapshot.ranked_items),
        empty: snapshot.repository_rollup.line_count.zero?
      }
    end

    private

    attr_reader :repository

    def line_facts
      @line_facts ||= file_paths.flat_map do |path|
        line_count = line_count_for(path)
        modified_at = modified_at_for(path)
        complexity = line_count >= 200 ? 5 : 0

        (1..line_count).map do |line_number|
          CognitiveCoverage::LineFact.new(
            path: path,
            line_number: line_number,
            last_modified_at: modified_at,
            complexity: line_number == 1 ? complexity : 0
          )
        end
      end
    end

    def file_paths
      @file_paths ||= (coverage_files.keys + engagement_events.filter_map(&:path)).uniq.sort
    end

    def line_count_for(path)
      stats = coverage_files[path] || {}
      [
        stats["line_count"].to_i,
        stats["covered_line_count"].to_i,
        max_engaged_line_by_path[path].to_i,
        1
      ].max
    end

    def modified_at_for(path)
      latest_diff_version_time_by_path[path] || latest_coverage_snapshot&.created_at || repository.updated_at
    end

    def target_sha
      @target_sha ||= repository.last_health_checked_sha.presence || latest_coverage_snapshot&.sha.to_s.presence || repository.default_branch
    end

    def latest_coverage_snapshot
      @latest_coverage_snapshot ||= CoverageSnapshot
        .where(repository: repository)
        .for_project(TargetGraph::ROOT_PROJECT_ID)
        .on_branch(repository.default_branch)
        .order(created_at: :desc)
        .first
    end

    def coverage_files
      @coverage_files ||= latest_coverage_snapshot&.data || {}
    end

    def engagement_events
      @engagement_events ||= CognitiveEngagementEvent
        .where(repository: repository)
        .includes(diff_review_version: :job)
        .order(occurred_at: :desc, id: :desc)
        .to_a
    end

    def max_engaged_line_by_path
      @max_engaged_line_by_path ||= engagement_events.each_with_object(Hash.new(0)) do |event, max_by_path|
        next if event.path.blank?

        max_by_path[event.path] = [ max_by_path[event.path], event.end_line.to_i, event.start_line.to_i ].max
      end
    end

    def change_frequency
      @change_frequency ||= recent_file_snapshots.each_with_object(Hash.new(0)) do |file, counts|
        path = file_value(file, "path").to_s
        counts[path] += 1 if path.present?
      end.to_h
    end

    def recent_file_snapshots
      @recent_file_snapshots ||= DiffReviewVersion
        .joins(:job)
        .where(jobs: { repository_id: repository.id })
        .where(created_at: CHURN_LOOKBACK.ago..)
        .pluck(:files_snapshot)
        .flat_map { |snapshot| Array(snapshot) }
    end

    def latest_diff_version_time_by_path
      @latest_diff_version_time_by_path ||= DiffReviewVersion
        .joins(:job)
        .where(jobs: { repository_id: repository.id })
        .order(created_at: :desc)
        .pluck(:created_at, :files_snapshot)
        .each_with_object({}) do |(created_at, files), times|
          Array(files).each do |file|
            path = file_value(file, "path").to_s
            times[path] ||= created_at if path.present?
          end
        end
    end

    def target_health_records
      @target_health_records ||= TargetHealthRecord.where(repository: repository, commit_sha: target_sha).latest_first.limit(20).to_a
    end

    def review_queue_json(items)
      items
        .select { |item| item.kind == "file" }
        .first(REVIEW_QUEUE_LIMIT)
        .map { |item| ranked_item_json(item) }
    end

    def ranked_item_json(item)
      rollup = item.rollup
      {
        kind: item.kind,
        path: item.key,
        risk_score: item.risk_score,
        coverage_state: item.coverage_state,
        explanations: item.explanations,
        rollup: rollup_json(rollup),
        signals: {
          churn: item.signals[:churn].to_i,
          test_coverage_pct: item.signals[:test_coverage_pct]&.round(2),
          unhealthy_target: item.signals[:unhealthy_target],
          reliability: item.signals[:reliability]
        },
        source: source_metadata_for(item.key)
      }
    end

    def rollup_json(rollup)
      line_count = rollup.line_count.to_i
      covered = rollup.covered_count.to_i
      stale = rollup.stale_count.to_i
      blind = rollup.blind_count.to_i
      engaged = covered + stale

      {
        key: rollup.key,
        line_count: line_count,
        covered_count: covered,
        stale_count: stale,
        blind_count: blind,
        cognitive_coverage_pct: line_count.positive? ? (engaged.fdiv(line_count) * 100.0).round(1) : nil
      }
    end

    def source_metadata_for(path)
      event = engagement_events.find { |candidate| candidate.path == path }
      line = event&.start_line || 1
      {
        github_url: github_file_url(path, line),
        review_path: review_path_for(event),
        latest_engagement: latest_engagement_json(event)
      }
    end

    def github_file_url(path, line)
      ref = target_sha == repository.default_branch ? repository.default_branch : target_sha
      "https://github.com/#{repository.slug}/blob/#{ref}/#{path}#L#{line}"
    end

    def review_path_for(event)
      job = event&.diff_review_version&.job
      job ? "/jobs/#{job.id}?tab=review" : nil
    end

    def latest_engagement_json(event)
      return nil unless event

      {
        source_type: event.source_type,
        engagement_kind: event.engagement_kind,
        occurred_at: event.occurred_at.iso8601,
        start_line: event.start_line,
        end_line: event.end_line
      }
    end

    def file_value(file, key)
      return file[key] if file.is_a?(Hash) && file.key?(key)
      return file[key.to_sym] if file.is_a?(Hash) && file.key?(key.to_sym)

      file.public_send(key) if file.respond_to?(key)
    end
  end
end
