require "rails_helper"

RSpec.describe MainGraderWorkflowJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user) }
  let(:sha) { "abc123def456" }

  before do
    allow(StepDispatcher).to receive(:start_workflow)
  end

  it "creates a main_grader Job with the correct attributes" do
    expect {
      described_class.perform_now(repository.id, sha)
    }.to change(Job, :count).by(1)

    job = Job.last
    expect(job.kind).to eq("main_grader")
    expect(job.repository).to eq(repository)
    expect(job.user).to eq(user)
    expect(job.issue_title).to eq("main_grader:#{sha}")
  end

  it "creates a main_grader Workflow with the SHA artifact" do
    expect {
      described_class.perform_now(repository.id, sha)
    }.to change(Workflow, :count).by(1)

    workflow = Workflow.last
    expect(workflow.trigger_kind).to eq("main_grader")
    expect(workflow.artifact("main_sha")).to eq(sha)
  end

  it "materializes prepare → grader_fanout → grader_collect steps" do
    described_class.perform_now(repository.id, sha)

    step_kinds = Workflow.last.steps.order(:position).pluck(:kind)
    expect(step_kinds).to eq(%w[ prepare grader_fanout grader_collect ])
  end

  it "calls StepDispatcher.start_workflow" do
    expect(StepDispatcher).to receive(:start_workflow).once
    described_class.perform_now(repository.id, sha)
  end

  it "does not record last_graded_sha before the grader workflow settles" do
    described_class.perform_now(repository.id, sha)
    expect(repository.reload.last_graded_sha).to be_nil
  end

  it "returns early when the repository does not exist" do
    expect {
      described_class.perform_now(0, sha)
    }.not_to change(Job, :count)
  end

  it "returns early for archived repositories" do
    repository.archive!

    expect {
      described_class.perform_now(repository.id, sha)
    }.not_to change(Job, :count)
  end

  it "skips creation when an open main_grader job already exists for the same SHA" do
    Job.create!(
      user: user,
      repository: repository,
      kind: "main_grader",
      issue_title: "main_grader:#{sha}",
      issue_number: nil
    )

    expect {
      described_class.perform_now(repository.id, sha)
    }.not_to change(Job, :count)
  end

  it "skips creation when an open main_grader job exists for a different SHA" do
    Job.create!(
      user: user,
      repository: repository,
      kind: "main_grader",
      issue_title: "main_grader:oldsha",
      issue_number: nil
    )

    expect {
      described_class.perform_now(repository.id, sha)
    }.not_to change(Job, :count)
  end

  it "does not update last_graded_sha when skipping due to an active grading job" do
    repository.update_columns(last_graded_sha: "previoussha")
    Job.create!(
      user: user,
      repository: repository,
      kind: "main_grader",
      issue_title: "main_grader:oldsha",
      issue_number: nil
    )

    described_class.perform_now(repository.id, sha)
    expect(repository.reload.last_graded_sha).to eq("previoussha")
  end

  it "skips creation while a main branch repair job is active for the same SHA" do
    Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
      issue_title: Job::MAIN_BRANCH_REPAIR_TITLE,
      issue_body: "Main branch health is broken.\nCommit: #{sha}\n",
      issue_number: nil
    )

    expect {
      described_class.perform_now(repository.id, sha)
    }.not_to change(Job, :count)

    expect(StepDispatcher).not_to have_received(:start_workflow)
  end

  it "allows creation while only stale main branch repair jobs are active" do
    Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
      issue_title: Job::MAIN_BRANCH_REPAIR_TITLE,
      issue_body: "Main branch health is broken.\nCommit: 111123def456\n",
      issue_number: nil
    )

    expect {
      described_class.perform_now(repository.id, sha)
    }.to change(Job, :count).by(1)

    expect(StepDispatcher).to have_received(:start_workflow).once
  end

  it "keeps legacy repair jobs without a target SHA blocking main grading" do
    Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
      issue_title: Job::MAIN_BRANCH_REPAIR_TITLE,
      issue_body: "Main branch health is broken.",
      issue_number: nil
    )

    expect {
      described_class.perform_now(repository.id, sha)
    }.not_to change(Job, :count)

    expect(StepDispatcher).not_to have_received(:start_workflow)
  end

  it "allows creation after a main branch repair job has closed" do
    repair = Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
      issue_title: Job::MAIN_BRANCH_REPAIR_TITLE,
      issue_number: nil
    )
    repair.update_columns(state: "closed", finished_at: Time.current)

    expect {
      described_class.perform_now(repository.id, sha)
    }.to change(Job, :count).by(1)
  end

  it "creates a new workflow when a closed main_grader job exists for the same SHA" do
    closed_job = Job.create!(
      user: user,
      repository: repository,
      kind: "main_grader",
      issue_title: "main_grader:#{sha}",
      issue_number: nil
    )
    closed_job.update_columns(state: "closed", finished_at: Time.current)

    expect {
      described_class.perform_now(repository.id, sha)
    }.to change(Job, :count).by(1)
  end

  it "skips creation when a conclusive grader result already exists for the SHA" do
    MainBranchHealthCheck.record_grader_workflow(repository: repository, sha: sha, grader_health: "healthy")

    expect {
      described_class.perform_now(repository.id, sha)
    }.not_to change(Job, :count)

    expect(StepDispatcher).not_to have_received(:start_workflow)
  end

  it "allows creation when the only prior grader result for the SHA is unknown" do
    MainBranchHealthCheck.record_grader_workflow(repository: repository, sha: sha, grader_health: "unknown")

    expect {
      described_class.perform_now(repository.id, sha)
    }.to change(Job, :count).by(1)
  end
end
