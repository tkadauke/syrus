require "rails_helper"

RSpec.describe "SyrusChatMcp CI repair tools" do
  let(:admin) { Factories.user(admin: true, github_token: "ghp_admin") }
  let(:repository) { Factories.repository(user: admin, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: admin) }
  let(:job) do
    Factories.job_record(
      user: admin,
      repository: repository,
      state: "implemented",
      branch_name: "syrus/direct-2265",
      pr_number: 2265,
      last_ci_handled_sha: sha
    )
  end
  let(:sha) { "2265abcdef000000000000000000000000000000" }
  let(:base_sha) { "base#{sha[4..]}" }
  let(:client) { instance_double(GithubClient) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        Mcp::Tools::RefreshPrChecksTool,
        Mcp::Tools::RerunCiRepairTool,
        Mcp::Tools::MarkCiRepairNoopTool
      ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(name, arguments)
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: name, arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload_for(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  before do
    pr = double("PullRequest", head: double("Head", sha: sha), base: double("Base", sha: base_sha))
    repository.update!(
      last_health_checked_sha: base_sha,
      last_ci_evaluated_sha: base_sha,
      last_graded_sha: base_sha,
      ci_health: "healthy",
      grader_health: "healthy"
    )
    allow(GithubClient).to receive(:for).with(repository: repository, user: admin).and_return(client)
    allow(client).to receive(:pull_request).with("acme/widgets", 2265, bypass_cache: true).and_return(pr)
    allow(client).to receive(:check_runs_detail_for).with("acme/widgets", sha).and_return(
      pending?: false,
      any_failed?: true,
      all_passed?: false,
      failed_checks: [
        { name: "rspec", conclusion: "failure", summary: "1 failure", html_url: "https://github.com/acme/widgets/runs/1" }
      ]
    )
  end

  it "refreshes PR checks immediately and returns failing check links" do
    response = call_tool("refresh_pr_checks", { job_id: job.id })
    payload = payload_for(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload).to include(job_id: job.id, slug: job.slug, head_sha: sha, pr_checks_state: "failing")
    expect(payload.fetch(:failing_checks)).to include(
      include(name: "rspec", details_url: "https://github.com/acme/widgets/runs/1")
    )
    expect(job.reload.pr_checks_state).to eq("failing")
  end

  it "creates a confirmed rerun action with failing-check evidence before confirmation" do
    response = call_tool(
      "rerun_ci_repair",
      {
        job_id: job.id,
        reason: "JOB-2265 stayed red after repair.",
        instructions: "Compare the prior ci_failure diff and check log."
      }
    )
    payload = payload_for(response)
    action = ChatPendingAction.find(payload.fetch(:pending_confirmation_id))

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload.fetch(:message)).to include("Failing checks: rspec (https://github.com/acme/widgets/runs/1)")
    expect(action).to have_attributes(action: "rerun_ci_repair", reason: "JOB-2265 stayed red after repair.")
    expect(action.payload).to include(
      "job_id" => job.id,
      "clear_handled_sha" => true,
      "instructions" => "Compare the prior ci_failure diff and check log.",
      "observed_head_sha" => sha
    )
    expect(action.payload.fetch("observed_failed_checks")).to include(
      include("name" => "rspec", "details_url" => "https://github.com/acme/widgets/runs/1")
    )
  end

  it "confirms rerun_ci_repair by starting a ci_failure workflow with audit snapshots" do
    response = call_tool("rerun_ci_repair", { job_id: job.id, reason: "JOB-2265 stayed red." })
    action = ChatPendingAction.find(payload_for(response).fetch(:pending_confirmation_id))

    expect {
      expect(action.confirm!).to be true
    }.to change { job.workflows.where(trigger_kind: "ci_failure").count }.by(1)

    workflow = action.reload.result
    expect(workflow).to have_attributes(job: job, trigger_kind: "ci_failure")
    expect(workflow.artifact("manual_ci_repair")).to include("reason" => "JOB-2265 stayed red.")
    expect(action.before_snapshot).to include("jobs")
    expect(action.after_snapshot).to include("jobs")
  end

  it "creates and confirms a no-op marker that escalates the landing explanation" do
    workflow = Workflows::CiFailure.instantiate(job: job, artifacts: { "head_sha" => sha, "failed_checks" => [] })

    response = call_tool(
      "mark_ci_repair_noop",
      { job_id: job.id, workflow_id: workflow.id, reason: "The repair produced no branch or check progress." }
    )
    payload = payload_for(response)
    action = ChatPendingAction.find(payload.fetch(:pending_confirmation_id))

    expect(payload.fetch(:message)).to include("Current checks: failing")
    expect(payload.fetch(:message)).to include("rspec (https://github.com/acme/widgets/runs/1)")
    expect(action).to have_attributes(action: "mark_ci_repair_noop")

    expect(action.confirm!).to be true
    expect(workflow.reload.artifact("ci_repair_noop")).to include(
      "reason" => "The repair produced no branch or check progress.",
      "observed_head_sha" => sha,
      "observed_pr_checks_state" => "failing"
    )
    expect(job.reload.landing_failure_reason).to include("ci_repair_noop")
  end

  it "creates a grouped pending action for mark_ci_repair_noop workflow_ids sharing one reason" do
    other_job = Factories.job_record(
      user: admin,
      repository: repository,
      issue_number: 2266,
      state: "implemented",
      branch_name: "syrus/direct-2266",
      pr_number: 2266,
      last_ci_handled_sha: sha
    )
    workflow_one = Workflows::CiFailure.instantiate(job: job, artifacts: { "head_sha" => sha, "failed_checks" => [] })
    workflow_two = Workflows::CiFailure.instantiate(job: other_job, artifacts: { "head_sha" => sha, "failed_checks" => [] })
    other_pr = double("PullRequest", head: double("Head", sha: sha), base: double("Base", sha: base_sha))
    allow(client).to receive(:pull_request).with("acme/widgets", 2266, bypass_cache: true).and_return(other_pr)

    response = call_tool(
      "mark_ci_repair_noop",
      { workflow_ids: [ workflow_one.id, workflow_two.id ], reason: "Both repairs made no branch or check progress." }
    )
    body = payload_for(response)
    group = PendingActionGroup.find(body.fetch(:pending_action_group_id))

    expect(response.dig(:result, :isError)).to be_falsey
    expect(body).to include(state: "pending", member_count: 2, message: "Mark 2 CI repairs as no-op?")
    expect(group.reason).to eq("Both repairs made no branch or check progress.")
    expect(group.chat_pending_actions.map { |a| a.payload["workflow_id"] }).to contain_exactly(workflow_one.id, workflow_two.id)
    expect(group.chat_pending_actions.map { |a| a.payload["job_id"] }).to contain_exactly(job.id, other_job.id)

    result = group.confirm_all!(user: admin)

    expect(result).to be_all_succeeded
    expect(workflow_one.reload.artifact("ci_repair_noop")).to include("reason" => "Both repairs made no branch or check progress.")
    expect(workflow_two.reload.artifact("ci_repair_noop")).to include("reason" => "Both repairs made no branch or check progress.")
  end

  it "rejects mark_ci_repair_noop workflow_ids with a blank reason" do
    workflow = Workflows::CiFailure.instantiate(job: job, artifacts: { "head_sha" => sha, "failed_checks" => [] })

    response = call_tool("mark_ci_repair_noop", { workflow_ids: [ workflow.id ], reason: "   " })

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("reason is required")
    expect(PendingActionGroup.count).to eq(0)
    expect(ChatPendingAction.where(action: "mark_ci_repair_noop")).to be_empty
  end
end
