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
      return if context.destination_path.blank?

      rows = runtime_rows
      return if rows.empty?

      destination = context.workspace_path.join(context.destination_path)
      FileUtils.mkdir_p(destination.dirname)
      File.write(destination, rows.map { |file_path, seconds| "#{file_path}:#{format('%.2f', seconds)}" }.join("\n") + "\n")
    end

    private

    attr_reader :context

    def rspec_grader?
      context.grader_definition.to_h["grader_framework"] == "rspec"
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
