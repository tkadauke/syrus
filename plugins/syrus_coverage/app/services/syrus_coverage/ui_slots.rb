module SyrusCoverage
  # Contributes the coverage card to the Job page and the trend sparkline to the
  # repository page, so core renders neither by name.
  class UiSlots
    include Syrus::Host::UiSlot

    ARTIFACT_KEYS = %w[
      coverage_unavailable files hit_map_attached pr_delta projects sources_status
      summary threshold_miss threshold_miss_details
    ].freeze

    def self.ui_slots(slot:, context:)
      case slot
      when "job.detail" then job_panels(context[:job])
      when "repository.detail" then [ { id: "syrus_coverage.trend", component: "syrus_coverage/CoverageSparkline", order: 90 } ]
      else []
      end
    end

    def self.job_panels(job)
      return [] if job.blank?

      coverage = latest_coverage(job)
      return [] if coverage.nil?

      [ { id: "syrus_coverage.card", component: "syrus_coverage/CoverageCard", order: 30, cacheable: false, props: { coverage: coverage } } ]
    end

    # The newest workflow's coverage artifact, trimmed to what the card renders
    # (the hit map and PR comment body stay server-side).
    def self.latest_coverage(job)
      entry = job.workflows.filter_map do |workflow|
        next unless workflow.artifacts.is_a?(Hash)

        coverage = workflow.artifact("coverage")
        [ workflow, coverage ] if coverage.is_a?(Hash)
      end.max_by { |workflow, _| [ workflow.created_at || Time.zone.at(0), workflow.id ] }
      entry&.last&.slice(*ARTIFACT_KEYS)
    end
  end
end
