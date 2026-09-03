module TestInsights
  class UiSlots
    include Syrus::Plugin::UiSlot

    # The Job detail Tests tab. Contributed only when this Job actually has
    # results, which is why core no longer needs a has_test_results? of its own.
    def self.ui_slots(slot:, context:)
      return [] unless slot == "job.detail.tab"

      job = context[:job]
      return [] if job.blank?
      return [] unless results?(job)

      [
        {
          id: "test_insights.job_tests",
          key: "tests",
          label: "Tests",
          label_key: "test_insights:tab_tests",
          component: "test_insights/JobTests",
          order: 40,
          props: { job_id: job.id }
        }
      ]
    end

    def self.results?(job)
      run_ids = Run.joins(step: :workflow).where(workflows: { job_id: job.id }).select(:id)
      TestRun.where(run_id: run_ids).exists?
    end
  end
end
