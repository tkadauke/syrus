require "rails_helper"

RSpec.describe ReconcileIntegrationBranchesJob do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:client) { instance_double(GithubClient, list_open_pull_requests: [], branch_head_sha: "train-sha", delete_branch: true) }

  before { allow(GithubClient).to receive(:for).and_return(client) }

  it "reconciles bounded terminal Epic and legacy job-bundle integration branches" do
    epic = Factories.epic(repository: repository, user: user)
    epic_train = MergeTrain.create!(epic: epic, repository: repository, base_branch: repository.default_branch,
      state: "succeeded", finished_at: 2.days.ago, integration_branch: "syrus/merge-train-1", integration_sha: "train-sha")
    bundle = MergeTrain.create!(repository: repository, priority: "medium", base_branch: repository.default_branch,
      state: "failed", finished_at: 3.days.ago, integration_branch: "syrus/job-bundle-1", integration_sha: "train-sha")
    [ epic_train, bundle ].each do |train|
      job = Factories.job_record(user: user, repository: repository, state: "closed")
      MergeTrainMember.create!(merge_train: train, job: job, position: 0)
    end

    described_class.perform_now

    expect(epic_train.reload.branch_deleted_at).to be_present
    expect(bundle.reload.branch_deleted_at).to be_present
  end

  it "rotates failed candidates so they cannot starve later trains" do
    stub_const("#{described_class}::MAX_BRANCHES_PER_RUN", 1)
    trains = 2.times.map do |index|
      train = MergeTrain.create!(repository: repository, priority: "medium", base_branch: repository.default_branch,
        state: "failed", finished_at: (3 - index).days.ago, integration_branch: "syrus/job-bundle-#{index}", integration_sha: "train-sha")
      MergeTrainMember.create!(merge_train: train, job: Factories.job_record(user: user, repository: repository, state: "closed"), position: 0)
      train
    end
    allow(client).to receive(:delete_branch).and_return(false, true)

    described_class.perform_now
    described_class.perform_now

    expect(trains.first.reload.branch_deleted_at).to be_nil
    expect(trains.last.reload.branch_deleted_at).to be_present
  end
end
