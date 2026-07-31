require "rails_helper"

RSpec.describe Prompts::MergeTrainReconcile do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:epic) do
    Factories.epic(
      user: user,
      repository: repository,
      title: "Unify billing flows",
      description: "Keep checkout and invoice screens consistent."
    )
  end
  let(:job) do
    Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_title: "Add invoice export",
      pr_number: 42,
      branch_name: "syrus/issue-42"
    )
  end

  subject(:out) do
    described_class.new(
      epic: epic,
      jobs: [ job ],
      repo_slug: repository.slug,
      integration_branch: "syrus/merge-train-epic-1-2",
      base_branch: "main"
    ).to_s
  end

  it "orients the agent to the integration branch and Epic members" do
    expect(out).to include("Epic merge-train reconciliation")
    expect(out).to include("syrus/merge-train-epic-1-2")
    expect(out).to include("Unify billing flows")
    expect(out).to include(job.slug)
    expect(out).to include("PR #42")
  end

  it "allows no-diff success and requires transcript evidence" do
    expect(out).to include("A no-diff result is a successful reconciliation")
    expect(out).to include("Summary")
    expect(out).to include("Test evidence")
  end

  it "keeps normal Syrus git safety instructions" do
    expect(out).to include(Prompts::GitSafety::TEXT)
  end
end
