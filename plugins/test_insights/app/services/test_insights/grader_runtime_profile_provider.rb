module TestInsights
  class GraderRuntimeProfileProvider
    MIN_SECONDS = 0.01

    def self.materialize_grader_inputs(context)
      new(context).materialize
    end

    def initialize(context)
      @context = context
    end

    def materialize
      return unless rspec_grader?

      materialize_shard_profile
      return if context.destination_path.blank?

      rows = runtime_rows
      return if rows.empty?

      write_profile(context.destination_path, rows)
    end

    private

    attr_reader :context

    def rspec_grader?
      context.grader_definition.to_h["grader_framework"] == "rspec"
    end

    # A sharded grader splits the whole suite by runtime, so it needs every
    # file's runtime -- not only the files its own grader name has run -- and
    # every shard of the round needs the same numbers. See ShardRuntimeSnapshot.
    def materialize_shard_profile
      destination = context.grader_definition.to_h["shard_runtime_profile_destination"].presence
      grader_key = context.grader_definition.to_h["shard_runtime_profile_key"].presence
      source_snapshot_id = context.step&.details.to_h["source_snapshot_id"].presence
      return unless destination && grader_key && source_snapshot_id

      snapshot = ShardRuntimeSnapshot.fetch(
        repository: context.repository, grader_key: grader_key, source_snapshot_id: Integer(source_snapshot_id)
      ) { render_profile(suite_rows) }
      return if snapshot.profile.blank?

      path = context.workspace_path.join(destination)
      FileUtils.mkdir_p(path.dirname)
      File.write(path, snapshot.profile)
    end

    def suite_rows
      suite_durations_by_file.map { |file_path, duration_ms| [ file_path, [ duration_ms.to_f / 1_000.0, MIN_SECONDS ].max ] }.sort_by(&:first)
    end

    def suite_durations_by_file
      RuntimeSummary
        .joins(:test_identity)
        .where(repository_id: context.repository.id, grader_name: RuntimeSummary::ALL_GRADERS, window: RuntimeSummary::RECENT_100_WINDOW)
        .where.not(avg_duration_ms: nil)
        .where.not(test_insight_identities: { file_path: nil })
        .where.not(test_insight_identities: { file_path: "" })
        .group("test_insight_identities.file_path")
        .sum(:avg_duration_ms)
    end

    def write_profile(relative_path, rows)
      destination = context.workspace_path.join(relative_path)
      FileUtils.mkdir_p(destination.dirname)
      File.write(destination, render_profile(rows))
    end

    def render_profile(rows)
      return "" if rows.empty?

      rows.map { |file_path, seconds| "#{file_path}:#{format('%.2f', seconds)}" }.join("\n") + "\n"
    end

    def runtime_rows
      durations_by_file.filter_map do |file_path, duration_ms|
        next unless present_checkout_file?(file_path)

        [ file_path, [ duration_ms.to_f / 1_000.0, MIN_SECONDS ].max ]
      end.sort_by(&:first)
    end

    def durations_by_file
      RuntimeSummary
        .joins(:test_identity)
        .where(
          repository_id: context.repository.id,
          grader_name: context.grader_name,
          window: RuntimeSummary::RECENT_100_WINDOW
        )
        .where.not(avg_duration_ms: nil)
        .where.not(test_insight_identities: { file_path: nil })
        .where.not(test_insight_identities: { file_path: "" })
        .group("test_insight_identities.file_path")
        .sum(:avg_duration_ms)
    end

    def present_checkout_file?(file_path)
      relative = Pathname.new(file_path.to_s)
      return false if relative.absolute?

      context.workspace_path.join(relative).file?
    end
  end
end
