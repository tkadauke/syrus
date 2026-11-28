require "rails_helper"

RSpec.describe Coworkers::JobAutonomy do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:other_repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-autonomy", workspace_repo: repository.remote_url)
  end
  let(:own_job) { Factories.job_record(user: owner, repository:, filed_by_coworker_id: coworker.id) }

  def grant!(tool_name, repository_id: repository.id, constraints: { "mode" => "enabled" })
    capability = described_class::CAPABILITIES.fetch(tool_name)
    coworker.permission_rules.update!(
      capability:, approval_policy: "auto", scope: repository_id, constraints:, actor: owner
    )
  end

  it "keeps a newly granted capability in shadow mode while retaining guardrail evidence" do
    grant!("propose_job", constraints: {})

    decision = described_class.new(coworker).authorize(tool_name: "propose_job", repository:)

    expect(decision).not_to be_allowed
    expect(decision).to be_shadow
    expect(decision.evidence).to include("repository_id" => repository.id, "permission_rule_id" => decision.rule.id)
    expect(decision.guardrail_outcomes.fetch("open_job_budget")).to include("passed" => true, "count" => 0, "limit" => 3)
  end

  it "allows each scoped action only for the coworker's own Job" do
    described_class::CAPABILITIES.each_key { |tool_name| grant!(tool_name) }

    described_class::CAPABILITIES.each_key do |tool_name|
      if tool_name == "approve_job"
        workflow = Workflow.create!(job: own_job, trigger_kind: "initial")
        allow(Syrus::Host::ImmutableReviewHeadBarrier).to receive(:required_reviews_satisfied?).with(workflow).and_return(true)
      end
      decision = described_class.new(coworker).authorize(tool_name:, repository:, job: (own_job unless tool_name == "propose_job"))
      expect(decision).to be_allowed
      expect(decision.rule).to be_present
    end
  end

  it "refuses another coworker's Job and a repository outside the rule scope" do
    grant!("approve_job")
    foreign_job = Factories.job_record(user: owner, repository:)
    other_job = Factories.job_record(user: owner, repository: other_repository, filed_by_coworker_id: coworker.id)

    expect(described_class.new(coworker).authorize(tool_name: "approve_job", repository:, job: foreign_job)).not_to be_allowed
    expect(described_class.new(coworker).authorize(tool_name: "approve_job", repository: other_repository, job: other_job)).not_to be_allowed
  end

  it "does nothing without an allow grant" do
    expect(described_class.new(coworker).authorize(tool_name: "cancel_job", repository:, job: own_job)).not_to be_allowed
  end

  it "refuses at the open self-filed Job budget boundary with a clear reason" do
    grant!("propose_job", constraints: { "max_open_jobs" => 1 })
    own_job

    decision = described_class.new(coworker).authorize(tool_name: "propose_job", repository:)

    expect(decision).not_to be_allowed
    expect(decision.reason).to include("Open self-filed Job budget reached")
  end

  it "refuses at the feedback-round budget boundary" do
    grant!("submit_chat_feedback", constraints: { "max_feedback_rounds_per_job" => 1 })
    Workflow.create!(job: own_job, trigger_kind: "chat_feedback")

    decision = described_class.new(coworker).authorize(tool_name: "submit_chat_feedback", repository:, job: own_job)

    expect(decision).not_to be_allowed
    expect(decision.reason).to include("Feedback-round budget reached")
  end

  it "refuses at the daily self-approval budget boundary" do
    grant!("approve_job", constraints: { "max_self_approvals_per_day" => 1 })
    workflow = Workflow.create!(job: own_job, trigger_kind: "initial")
    allow(Syrus::Host::ImmutableReviewHeadBarrier).to receive(:required_reviews_satisfied?).with(workflow).and_return(true)
    Permissions::CoworkerAudit.record!("coworker_job_autonomy_action", owner:, coworker:,
      repository_id: repository.id, autonomous_action: "approve_job")

    decision = described_class.new(coworker).authorize(tool_name: "approve_job", repository:, job: own_job)

    expect(decision).not_to be_allowed
    expect(decision.reason).to include("Daily self-approval budget reached")
  end

  it "refuses approval when required reviews are stale" do
    grant!("approve_job")
    workflow = Workflow.create!(job: own_job, trigger_kind: "initial")
    allow(Syrus::Host::ImmutableReviewHeadBarrier).to receive(:required_reviews_satisfied?).with(workflow).and_return(false)

    decision = described_class.new(coworker).authorize(tool_name: "approve_job", repository:, job: own_job)

    expect(decision.reason).to include("current implementation HEAD")
  end

  it "refuses a sensitive change through the approval gate by default" do
    grant!("approve_job")
    workflow = Workflow.create!(job: own_job, trigger_kind: "initial")
    allow(Syrus::Host::ImmutableReviewHeadBarrier).to receive(:required_reviews_satisfied?).with(workflow).and_return(true)
    own_job.diff_review_versions.create!(version_index: 1, base_sha: "base", head_sha: "head", source_key: "final",
      reason: "source_diff", files_snapshot: [{ "path" => "db/schema.rb", "status" => "modified" }],
      metadata: {}, truncated: false)

    decision = described_class.new(coworker).authorize(tool_name: "approve_job", repository:, job: own_job)

    expect(decision).not_to be_allowed
    expect(decision.reason).to include("Sensitive change requires operator approval")
  end

  it "refuses a bug fix when its regression proof is not proven" do
    grant!("approve_job")
    own_job.update!(bug_fix: true)
    workflow = Workflow.create!(job: own_job, trigger_kind: "initial")
    allow(Syrus::Host::ImmutableReviewHeadBarrier).to receive(:required_reviews_satisfied?).with(workflow).and_return(true)
    allow(Coworkers::RegressionProof).to receive(:call).with(own_job).and_return(
      Coworkers::RegressionProof::Result.new(false, "base_passed")
    )

    decision = described_class.new(coworker).authorize(tool_name: "approve_job", repository:, job: own_job)

    expect(decision).not_to be_allowed
    expect(decision.reason).to include("fails on the base revision and passes on the branch")
  end
end
