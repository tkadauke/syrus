module SyrusCoverage
  # The coverage card on the Job detail page and the trend sparkline on the
  # repository page. Both are the plugin's own React components, so a disabled
  # plugin renders neither and core carries no coverage presentation for them.
  class UiSlots
    include Syrus::Plugin::UiSlot

    # The fields of the artifact the card renders; the raw artifact can also
    # carry per-line annotations the card never shows.
    CARD_FIELDS = %w[
      coverage_unavailable files hit_map_attached pr_delta projects sources_status
      summary threshold_miss threshold_miss_details
    ].freeze

    def self.ui_slots(slot:, context:)
      case slot
      when "job.detail" then job_card(context[:job])
      when "repository.detail" then [ { id: "syrus_coverage.trend", component: "syrus_coverage/CoverageSparkline", order: 90 } ]
      else []
      end
    end

    def self.job_card(job)
      return [] if job.blank?

      artifact = latest_artifact(job)
      return [] if artifact.nil?

      [ { id: "syrus_coverage.card", component: "syrus_coverage/CoverageCard", order: 30, props: { coverage: artifact.slice(*CARD_FIELDS) } } ]
    end

    def self.latest_artifact(job)
      job.workflows.filter_map do |workflow|
        next unless workflow.artifacts.is_a?(Hash)

        artifact = SyrusCoverage::Artifact.read(workflow)
        [ workflow, artifact ] if artifact.is_a?(Hash)
      end.max_by { |workflow, _| [ workflow.created_at || Time.zone.at(0), workflow.id ] }&.last
    end
    private_class_method :job_card, :latest_artifact
  end
end
