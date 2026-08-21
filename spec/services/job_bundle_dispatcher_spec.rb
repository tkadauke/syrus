require "rails_helper"

RSpec.describe JobBundleDispatcher do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }

  def approved_job(issue_number, priority: "medium")
    Factories.job_record(
      user: user, repository: repository,
      issue_number: issue_number, state: "approved", priority: priority,
      pr_number: 500 + issue_number, branch_name: "syrus/issue-#{issue_number}"
    )
  end

  before do
    Feature.create!(slug: "epicless_job_bundling", category: "Labs", name: "Epicless Job bundling", enabled: true)
    allow(StepDispatcher).to receive(:start_workflow)
  end

  it "creates a bundle-backed train, locks members into :landing, and starts the workflow" do
    a = approved_job(1)
    b = approved_job(2)

    expect(described_class.blocker_reason(repository)).to be_nil
    workflow = described_class.try_dispatch!(repository)

    expect(workflow).to be_present
    expect(workflow.trigger_kind).to eq("merge_train")
    train = MergeTrain.last
    expect(train.epic_id).to be_nil
    expect(train.priority).to eq("medium")
    expect(train.repository).to eq(repository)
    expect(train.base_branch).to eq(repository.default_branch)
    expect(train.members.count).to eq(2)
    expect(workflow.artifact("merge_train_id")).to eq(train.id)
    expect(a.reload.state).to eq("landing")
    expect(b.reload.state).to eq("landing")
    expect(StepDispatcher).to have_received(:start_workflow).with(workflow)
  end

  it "does nothing when the feature flag is disabled" do
    Feature.find_by(slug: "epicless_job_bundling").update!(enabled: false)
    approved_job(1)
    approved_job(2)

    expect(described_class.blocker_reason(repository)).to eq("epicless job bundling is disabled")
    expect(described_class.try_dispatch!(repository)).to be_nil
    expect(MergeTrain.count).to eq(0)
  end

  it "does nothing when there are fewer than 2 same-tier candidates" do
    approved_job(1)

    expect(described_class.try_dispatch!(repository)).to be_nil
    expect(MergeTrain.count).to eq(0)
  end

  it "does nothing when the repository already has a landing in progress" do
    approved_job(1)
    approved_job(2)
    Factories.job_record(user: user, repository: repository, issue_number: 99, state: "landing", pr_number: 999)

    expect(described_class.try_dispatch!(repository)).to be_nil
    expect(MergeTrain.count).to eq(0)
  end

  it "does not dispatch a second bundle when the repository already has an active job bundle" do
    approved_job(1)
    approved_job(2)
    active_train = MergeTrain.create!(repository: repository, base_branch: "master", priority: "medium", state: "grading")

    expect(described_class.try_dispatch!(repository)).to be_nil
    expect(MergeTrain.all).to contain_exactly(active_train)
    expect(StepDispatcher).not_to have_received(:start_workflow)
  end

  it "is unaffected by an active Epic-backed merge train in the same repository (blocked by the shared landing slot instead)" do
    epic = Factories.epic(user: user, repository: repository)
    epic_child = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 50, state: "landing", pr_number: 950)
    MergeTrain.create!(epic: epic, repository: repository, base_branch: "master", state: "grading")
    approved_job(1)
    approved_job(2)

    expect(described_class.blocker_reason(repository)).to eq("#{epic_child.slug} is already landing for #{repository.slug}")
    expect(described_class.try_dispatch!(repository)).to be_nil
  end

  it "does not dispatch while a rebase workflow is active for a bundle member" do
    a = approved_job(1)
    approved_job(2)
    workflow = Workflow.create!(job: a, trigger_kind: "rebase", state: "running")
    Step.create!(workflow: workflow, kind: "agent_rebase", position: 0)

    expect(described_class.blocker_reason(repository)).to eq("active rebase workflow #{workflow.slug} must finish before the job bundle starts")
    expect(described_class.try_dispatch!(repository)).to be_nil
    expect(MergeTrain.count).to eq(0)
  end

  it "does not re-dispatch during the cooldown after a failed bundle" do
    approved_job(1)
    approved_job(2)
    MergeTrain.create!(repository: repository, base_branch: "master", priority: "medium",
                       state: "failed", finished_at: 5.minutes.ago)

    expect(described_class.try_dispatch!(repository)).to be_nil
    expect(MergeTrain.where(state: "building").count).to eq(0)
  end

  it "allows explicit rebuilds to bypass the failed-bundle cooldown" do
    approved_job(1)
    approved_job(2)
    MergeTrain.create!(repository: repository, base_branch: "master", priority: "medium",
                       state: "failed", failure_reason: "merge_train failed", finished_at: 5.minutes.ago)

    expect(described_class.try_dispatch!(repository, bypass_cooldown: true)).to be_present
  end

  it "re-dispatches once the cooldown has elapsed" do
    approved_job(1)
    approved_job(2)
    MergeTrain.create!(repository: repository, base_branch: "master", priority: "medium",
                       state: "failed", finished_at: (described_class::RETRY_COOLDOWN + 1.minute).ago)

    expect(described_class.try_dispatch!(repository)).to be_present
  end

  it "re-dispatches immediately after a stale-base bundle failure, same as an Epic-backed train" do
    approved_job(1)
    approved_job(2)
    MergeTrain.create!(
      repository: repository, base_branch: "master", priority: "medium",
      state: "failed",
      failure_reason: "merge_train: base moved from oldbase to newbase; rebuild required",
      finished_at: 5.minutes.ago
    )

    expect(described_class.try_dispatch!(repository)).to be_present
  end

  it "re-dispatches immediately after an old bundle missing base tracking fails" do
    approved_job(1)
    approved_job(2)
    MergeTrain.create!(
      repository: repository, base_branch: "master", priority: "medium",
      state: "failed",
      failure_reason: "merge_train: missing built base SHA; rebuild required",
      finished_at: 5.minutes.ago
    )

    expect(described_class.try_dispatch!(repository)).to be_present
  end

  it "re-dispatches immediately after a transient landing-start blocker failure" do
    approved_job(1)
    approved_job(2)
    MergeTrain.create!(
      repository: repository, base_branch: "master", priority: "medium",
      state: "failed",
      failure_reason: "landing start blocked: dependency failed",
      finished_at: 5.minutes.ago
    )

    expect(described_class.try_dispatch!(repository)).to be_present
  end
end
