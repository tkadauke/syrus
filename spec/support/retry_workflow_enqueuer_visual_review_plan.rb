RSpec.configure do |config|
  config.before(:each, file_path: %r{/spec/services/retry_workflow_enqueuer_spec\.rb\z}) do
    visual_review_plan = SyrusBrowser::RepoVisualReviewPlan::Result.new(enabled: false, rounds: 1, source: "none", note: "disabled")

    allow(SyrusBrowser::RepoVisualReviewPlan).to receive(:from_syrus_yml).and_return(visual_review_plan)
    allow(SyrusBrowser::RepoVisualReviewPlan).to receive(:for_job).and_return(visual_review_plan)
  end
end
