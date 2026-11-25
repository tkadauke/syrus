require "rails_helper"

RSpec.describe JobDetachRepair do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner, default_branch: "main") }
  let(:parent) { Factories.job_record(user: owner, repository: repository, issue_number: 10066, pr_number: 10066, branch_name: "syrus/parent", state: "implemented") }
  let(:job) { Factories.job_record(user: owner, repository: repository, issue_number: 10068, pr_number: 10068, branch_name: "syrus/child", parent_job: parent, state: "implemented") }
  let!(:dependency) { JobDependency.create!(job: job, depends_on_job: parent, source: "manual", satisfaction_mode: "success") }
  let(:head) { "a" * 40 }
  let(:former_parent_head) { "b" * 40 }
  let(:owned_patch_base_sha) { "c" * 40 }
  let(:client) { instance_double(GithubClient) }
  let(:pr) { double("pull request", head: double("head", sha: head), base: double("base", ref: "main")) }

  def call_repair(auto_rebase)
    described_class.call(
      job: job, destination_base: "main", reason: "Repair accidental parent.", requested_by: "chat_agent",
      former_parent_id: parent.id, former_parent_head: former_parent_head,
      owned_patch_base_sha: owned_patch_base_sha, confirmed_head: head, auto_rebase: auto_rebase
    )
  end

  before do
    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:update_pull_request_base)
    allow(client).to receive(:branch_head_sha).and_return(head)
    allow(client).to receive(:pull_request).and_return(pr)
    allow(client).to receive(:update_pull_request_body)
    allow(LandingQueueProcessor).to receive(:refresh_snapshot!).and_return([])
    allow(LandingQueueProcessorJob).to receive(:perform_later)
    allow(PrStackFooter).to receive(:refresh!)
  end

  it "cleanly detaches, retargets, removes the former-parent dependency, verifies, and wakes landing" do
    rebase = instance_double(AutoRebase, call: AutoRebase::Result.new(true, "rebased", "ok", changed: true, pre_sha: "b" * 40, post_sha: head, base_sha: "c" * 40))

    result = call_repair(rebase)

    expect(result.status).to eq("verified")
    expect(job.reload.parent_job).to be_nil
    expect(job.dependencies.where(depends_on_job: parent)).to be_empty
    expect(client).to have_received(:update_pull_request_base).with(repository.slug, 10068, base: "main")
    expect(LandingQueueProcessorJob).to have_received(:perform_later)
  end

  it "uses an agentic rebase workflow only for a deterministic conflict" do
    conflict = AutoRebase::Result.new(false, "conflict", nil, pre_sha: head, base_sha: "c" * 40)
    rebase = instance_double(AutoRebase, call: conflict)
    workflow = instance_double(Workflow, id: 77)
    allow(WorkUnits::Launcher).to receive(:instantiate).and_return(workflow)
    allow(WorkUnits::Launcher).to receive(:start!)

    result = call_repair(rebase)

    expect(result.status).to eq("conflict_fallback")
    expect(WorkUnits::Launcher).to have_received(:instantiate).with(hash_including(
      kind: "rebase", job: job, base_branch: "main",
      artifacts: hash_including(
        "detach_job" => {
          "destination_base" => "main", "former_parent_id" => parent.id,
          "former_parent_head" => former_parent_head, "owned_patch_base_sha" => owned_patch_base_sha,
          "confirmed_head" => head
        }
      )
    ))
    expect(WorkUnits::Launcher).to have_received(:start!).with(workflow)
    expect(job.reload.parent_job).to eq(parent)
  end

  it "surfaces lease rejection without changing topology or retargeting the PR" do
    rejected = instance_double(AutoRebase, call: AutoRebase::Result.new(false, "lease_rejected", "remote moved", pre_sha: head))

    expect {
      call_repair(rejected)
    }.to raise_error(ArgumentError, /remote moved/)

    expect(job.reload.parent_job).to eq(parent)
    expect(client).not_to have_received(:update_pull_request_base)
  end

  it "refuses to act when the confirmed parent relationship changed" do
    job.update!(parent_job: nil)

    expect { call_repair(instance_double(AutoRebase)) }
      .to raise_error(ArgumentError, /Stack parent changed after confirmation/)
  end

  it "leaves topology intact when PR retargeting fails so retry can recover visibly" do
    allow(client).to receive(:update_pull_request_base).and_raise(Octokit::UnprocessableEntity)

    expect {
      described_class.finalize!(job: job, destination_base: "main", expected_head: head, reason: "Repair accidental parent.", client: client)
    }.to raise_error(Octokit::UnprocessableEntity)

    expect(job.reload.parent_job).to eq(parent)
    expect(dependency.reload).to be_present
  end

  it "can retry finalization after a prior publication already moved the branch" do
    evidence = described_class.finalize!(job: job, destination_base: "main", expected_head: head, reason: "Retry partial repair.", client: client)

    expect(evidence).to include("remote_head" => head, "pr_base" => "main", "parent_job_id" => nil)
    expect(job.reload.parent_job).to be_nil
  end

  it "fails postcondition verification instead of reporting success on stale live state" do
    allow(client).to receive(:branch_head_sha).and_return("d" * 40)

    expect {
      described_class.finalize!(job: job, destination_base: "main", expected_head: head, reason: "Repair accidental parent.", client: client)
    }.to raise_error(JobDetachPostconditionVerifier::Mismatch, /remote head/)
  end
end
