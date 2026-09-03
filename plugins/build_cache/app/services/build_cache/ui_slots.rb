module BuildCache
  class UiSlots
    include Syrus::Plugin::UiSlot

    def self.ui_slots(slot:, context:)
      return [] unless slot == "job.detail"

      job = context[:job]
      return [] if job.blank?

      summary = latest_stats_for(job)
      return [] if summary.nil?

      [ { id: "build_cache.sccache", component: "build_cache/SccacheCard", order: 40, props: { sccache: summary } } ]
    end

    # Latest sccache capture across this Job's Workflows, compared by the
    # capture's own captured_at rather than the owning workflow's created_at,
    # so an in-progress follow-up workflow with a fresher capture wins.
    #
    # Computed here rather than in core's job payload: a repository that never
    # compiles anything has no captures and gets no panel, and core does not
    # have to know what an sccache statistic is.
    def self.latest_stats_for(job)
      entry = job.workflows.filter_map do |workflow|
        next unless workflow.artifacts.is_a?(Hash)

        latest = StatsArtifact.read(workflow).last
        next unless latest.is_a?(Hash)

        [ workflow, latest ]
      end.max_by { |_workflow, latest| latest["captured_at"].to_s }
      return if entry.nil?

      workflow, latest = entry
      {
        workflow_id: workflow.id,
        run_id: latest["run_id"],
        step_kind: latest["step_kind"],
        label: latest["label"],
        iteration: latest["iteration"],
        captured_at: latest["captured_at"],
        summary: StatsSummary.for(latest["stats"]).to_h
      }
    end
  end
end
