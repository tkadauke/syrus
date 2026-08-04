require "rails_helper"

RSpec.describe JobRebasePlan do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  it "reports dry-run details for an approved dirty Job behind base" do
    job = Factories.job_record(
      user: user,
      repository: repository,
      state: "approved",
      branch_name: "syrus/direct-2265",
      pr_number: 2265,
      commits_behind_base: 4,
      pr_checks_state: "failure",
      github_mergeable_state: "dirty",
      landing_queue_position: 3,
      landing_queue_entry_position: 3,
      mergeability_base_ref: "main"
    )

    plan = described_class.for(job, bypass_front_of_queue: true)

    expect(plan).to include(
      "job_id" => job.id,
      "slug" => job.slug,
      "current_base" => "main",
      "target_base" => repository.default_branch,
      "pr_number" => 2265,
      "commits_behind" => 4,
      "checks_state" => "failure",
      "mergeable_state" => "dirty",
      "landing_queue_position" => 3,
      "workflow_trigger_kind" => "rebase",
      "bypass_front_of_queue" => true,
      "expected_landing_impact" => "successful rebase will retry landing immediately"
    )
    expect(plan.fetch("warnings")).to include("failing_or_pending_checks", "dirty_mergeability", "behind_base", "not_front_of_queue")
  end
end
