require "rails_helper"

RSpec.describe RetryWorkflowEnqueuer do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(repository: repository, agent_provider: "claude") }

  def finish_current_run!(state: "succeeded")
    run = job.current_run
    run.start! if run.may_start?
    state == "succeeded" ? run.succeed! : run.fail!
    run.save!
  end

  def github_issue_with_labels(*names)
    labels = names.map { |name| Struct.new(:name, keyword_init: true).new(name: name) }
    Struct.new(:labels, keyword_init: true).new(labels: labels)
  end

  it "creates and starts a retry workflow" do
    finish_current_run!

    expect {
      result = described_class.call(job: job)
      expect(result).to be_success
      expect(result.workflow.trigger_kind).to eq("retry")
    }.to change { job.workflows.where(trigger_kind: "retry").count }.by(1)
      .and have_enqueued_job(RunJob)

    workflow = job.workflows.where(trigger_kind: "retry").last
    expect(workflow.first_step.runs.last.agent_provider).to eq("claude")
  end

  it "persists an explicit provider on the job and retry workflow" do
    finish_current_run!
    user.update!(codex_auth_mode: "api_key", codex_api_key: "sk-test")

    result = described_class.call(job: job, agent_provider: "codex")

    expect(result).to be_success
    expect(job.reload.agent_provider).to eq("codex")
    expect(result.workflow.agent_provider).to eq("codex")
    expect(result.workflow.first_step.runs.last.agent_provider).to eq("codex")
  end

  it "rejects closed jobs" do
    finish_current_run!
    job.close_with_reason!("manual")

    expect {
      result = described_class.call(job: job)
      expect(result).not_to be_success
      expect(result.error).to eq("Thread is closed — use Start over to begin a new one.")
    }.not_to change { job.workflows.where(trigger_kind: "retry").count }
  end

  it "rejects jobs with an active run" do
    expect {
      result = described_class.call(job: job)
      expect(result).not_to be_success
      expect(result.error).to eq("A Run is already in progress — wait for it to finish.")
    }.not_to change { job.workflows.where(trigger_kind: "retry").count }
  end

  it "syncs skip-prepare from the source issue before instantiating the workflow" do
    finish_current_run!
    user.update!(github_token: "ghp_test_token")
    client = instance_double(GithubClient)
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    allow(client).to receive(:fetch_issue)
      .with(repository.slug, job.issue_number)
      .and_return(github_issue_with_labels("syrus", Workflows::SKIP_PREPARE_LABEL))

    result = described_class.call(job: job)

    expect(result).to be_success
    expect(job.reload).to be_skip_prepare
    expect(result.workflow.steps.order(:position).pluck(:kind)).to eq(%w[ implement grade summarize pr_open ])
  end

  it "can enforce alternate retry provider semantics for per-job retries" do
    finish_current_run!
    job.current_run.update!(agent_provider: "claude")
    job.latest_workflow.update!(state: "succeeded")
    user.update!(claude_oauth_token: "oat-test", codex_auth_mode: "api_key", codex_api_key: "sk-test")

    result = described_class.call(job: job, agent_provider: "claude", provider_validation: :retry_alternate)

    expect(result).not_to be_success
    expect(result.error).to eq("That agent is not available for retry.")
  end
end
