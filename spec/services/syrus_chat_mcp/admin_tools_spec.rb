require "rails_helper"

RSpec.describe "SyrusChatMcp admin tools" do
  before(:all) { ensure_solid_queue_test_tables! }
  after(:all) { drop_solid_queue_test_tables! }
  before { clear_solid_queue_test_tables! }

  let(:admin) { Factories.user(admin: true, email_address: "admin@example.com") }
  let(:user) { Factories.user(email_address: "user@example.com") }
  let(:repository) { Factories.repository(user: admin) }
  let(:admin_session) { ChatSession.create!(user: admin, repository: repository) }
  let(:user_session) { ChatSession.create!(user: user, repository: Factories.repository(user: user)) }

  before { admin }

  ADMIN_TOOLS = {
    "admin_overview" => {},
    "admin_stuck_jobs" => {},
    "admin_queue_detail" => { tab: "pending" },
    "admin_list_processes" => {},
    "admin_list_runs" => {},
    "admin_list_users" => {},
    "admin_version" => {},
    "admin_kill_process" => { process_id: 1 },
    "admin_reap_stale_runs" => {},
    "admin_pause_polling" => {},
    "admin_unpause_polling" => {},
    "admin_pause_runs" => {},
    "admin_unpause_runs" => {},
    "admin_clear_github_cache" => {},
    "admin_pause_user_scheduling" => { user_id: 1 },
    "admin_unpause_user_scheduling" => { user_id: 1 },
    "admin_retry_step" => { workflow_id: 1, step_slug: "implement" },
    "admin_cleanup_workspace" => { workflow_id: 1 },
    "admin_refresh_installations" => {}
  }.freeze

  def server_for(chat_session)
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: SyrusChatMcp::Sidecar::ADMIN_TOOLS,
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(chat_session, name, arguments = {})
    raw = server_for(chat_session).handle_json(
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }.to_json
    )
    JSON.parse(raw, symbolize_names: true)
  end

  def payload_for(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  def error_text(response)
    response.fetch(:result).fetch(:content).first.fetch(:text)
  end

  it "returns unauthorized errors for non-admin users at runtime" do
    ADMIN_TOOLS.each do |name, arguments|
      response = call_tool(user_session, name, arguments)

      expect(response.dig(:result, :isError)).to be(true), name
      expect(error_text(response)).to eq("Unauthorized: Admin access required")
    end
  end

  it "creates pending confirmations for admin side-effect tools" do
    process = SpawnedProcess.create!(
      kind: "agent",
      command: "codex exec",
      hostname: "worker-a",
      pid: 123,
      started_at: 2.minutes.ago
    )
    target_user = Factories.user(email_address: "target@example.com")
    workflow = Factories.job(user: admin, repository: repository).initial_run.step.workflow

    cases = {
      "admin_kill_process" => [ { process_id: process.id }, { "process_id" => process.id } ],
      "admin_reap_stale_runs" => [ {}, {} ],
      "admin_pause_polling" => [ {}, {} ],
      "admin_unpause_polling" => [ {}, {} ],
      "admin_pause_runs" => [ {}, {} ],
      "admin_unpause_runs" => [ {}, {} ],
      "admin_clear_github_cache" => [ {}, {} ],
      "admin_pause_user_scheduling" => [ { user_id: target_user.id }, { "user_id" => target_user.id } ],
      "admin_unpause_user_scheduling" => [ { user_id: target_user.id }, { "user_id" => target_user.id } ],
      "admin_retry_step" => [ { workflow_id: workflow.id, step_slug: "implement" }, { "workflow_id" => workflow.id, "step_slug" => "implement" } ],
      "admin_cleanup_workspace" => [ { workflow_id: workflow.id }, { "workflow_id" => workflow.id } ],
      "admin_refresh_installations" => [ {}, {} ]
    }

    cases.each do |name, (arguments, expected_payload)|
      response = call_tool(admin_session, name, arguments)
      payload = payload_for(response)
      action = ChatPendingAction.find(payload.fetch(:pending_confirmation_id))

      expect(response.dig(:result, :isError)).to be_falsey, name
      expect(payload).to include(state: "pending", message: a_string_matching(/\?/))
      expect(action).to have_attributes(
        chat_session: admin_session,
        user: admin,
        repository: repository,
        action: name,
        payload: expected_payload,
        requested_by: "agent"
      )
    end
  end

  it "rejects missing process and user targets gracefully" do
    process_response = call_tool(admin_session, "admin_kill_process", { process_id: 999_999 })
    user_response = call_tool(admin_session, "admin_pause_user_scheduling", { user_id: 999_999 })

    expect(process_response.dig(:result, :isError)).to be(true)
    expect(error_text(process_response)).to include("process not found: 999999")
    expect(user_response.dig(:result, :isError)).to be(true)
    expect(error_text(user_response)).to include("user not found: 999999")
    expect(ChatPendingAction.where(action: %w[admin_kill_process admin_pause_user_scheduling])).to be_empty
  end

  it "returns the admin overview data shape" do
    Factories.repository(user: admin)
    open_job = Factories.job(user: admin, repository: repository, issue_title: "Open job")
    workflow = open_job.initial_run.step.workflow
    workflow.update_columns(state: "running", started_at: 1.minute.ago)
    open_job.initial_run.update_columns(state: "running", started_at: 1.minute.ago)

    response = call_tool(admin_session, "admin_overview")
    payload = payload_for(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload).to include(
      :total_users,
      :active_repositories,
      :open_jobs,
      :running_workflows,
      :queue_summary,
      :overview
    )
    expect(payload[:total_users]).to be >= 1
    expect(payload[:active_repositories]).to be >= 1
    expect(payload[:open_jobs]).to be >= 1
    expect(payload[:running_workflows]).to eq(1)
    expect(payload[:queue_summary]).to include(:active, :pending, :failed)
  end

  it "returns stuck Jobs with Job, Workflow, and Run state" do
    job = Factories.job(user: admin, repository: repository, issue_title: "Silent run")
    run = job.initial_run
    workflow = run.step.workflow
    workflow.update_columns(state: "running", started_at: 10.minutes.ago)
    run.update_columns(state: "running", started_at: 10.minutes.ago, last_heartbeat_at: 10.minutes.ago)

    response = call_tool(admin_session, "admin_stuck_jobs")
    payload = payload_for(response)

    expect(payload.fetch(:items).first).to include(
      id: job.id,
      title: "Silent run",
      state: job.reload.state,
      last_heartbeat_at: run.reload.last_heartbeat_at.iso8601,
      workflow_state: "running",
      run_state: "running",
      workflow_id: workflow.id,
      run_id: run.id
    )
  end

  it "returns queue detail for a valid tab and an error for invalid tabs" do
    solid_queue_job(class_name: "RunJob", queue_name: "runs")

    response = call_tool(admin_session, "admin_queue_detail", { tab: "pending" })
    payload = payload_for(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload).to include(
      tab: "pending",
      jobs: array_including(hash_including(class_name: "RunJob")),
      total: 1
    )

    invalid = call_tool(admin_session, "admin_queue_detail", { tab: "missing" })
    expect(invalid.dig(:result, :isError)).to be(true)
    expect(error_text(invalid)).to include("tab must be one of active, pending, failed, recurring, workers")
  end

  it "returns SpawnedProcess rows with operational fields" do
    process = SpawnedProcess.create!(
      kind: "agent",
      command: "codex exec",
      hostname: "worker-a",
      pid: 123,
      started_at: 2.minutes.ago,
      last_chunk_at: 1.minute.ago
    )

    response = call_tool(admin_session, "admin_list_processes", { state: "running", limit: 5 })
    payload = payload_for(response)

    expect(payload.fetch(:processes).first).to include(
      id: process.id,
      kind: "agent",
      hostname: "worker-a",
      pid: 123,
      state: "running",
      last_heartbeat_at: process.last_chunk_at.iso8601
    )
  end

  it "returns Run rows with cross-Job metadata" do
    job = Factories.job(user: admin, repository: repository)
    run = job.initial_run
    run.update_columns(
      state: "succeeded",
      started_at: 3.minutes.ago,
      finished_at: 1.minute.ago,
      cost_usd: BigDecimal("0.120000")
    )

    response = call_tool(admin_session, "admin_list_runs", { state: "succeeded", job_id: job.id, limit: 5 })
    payload = payload_for(response)

    expect(payload.fetch(:runs).first).to include(
      id: run.id,
      job_id: job.id,
      workflow_id: run.step.workflow_id,
      state: "succeeded",
      trigger_kind: "initial",
      cost_usd: "0.12"
    )
  end

  it "returns users with account flags and Job counts" do
    Factories.job(user: admin, repository: repository)
    user.update!(scheduling_paused: true)

    response = call_tool(admin_session, "admin_list_users")
    payload = payload_for(response)

    admin_row = payload.fetch(:users).find { |row| row[:id] == admin.id }
    user_row = payload.fetch(:users).find { |row| row[:id] == user.id }
    expect(admin_row).to include(
      email: "admin@example.com",
      admin: true,
      agent_provider: admin.agent_provider,
      scheduling_paused: false,
      job_count: 1
    )
    expect(user_row).to include(email: "user@example.com", admin: false, scheduling_paused: true, job_count: 0)
  end

  it "returns live instance versions" do
    instance = InstanceVersion.create!(
      hostname: "syrus-worker-a",
      role: "worker",
      version: "abc123",
      started_at: 5.minutes.ago,
      last_heartbeat_at: 10.seconds.ago
    )

    response = call_tool(admin_session, "admin_version")
    payload = payload_for(response)

    expect(payload).to include(:request_handler, :instances)
    expect(payload.fetch(:instances).first).to include(
      id: instance.id,
      hostname: "syrus-worker-a",
      role: "worker",
      version: "abc123",
      started_at: instance.started_at.iso8601
    )
  end

  def solid_queue_job(class_name:, queue_name:)
    SolidQueue::Job.create!(
      class_name: class_name,
      queue_name: queue_name,
      priority: 0,
      arguments: { "arguments" => [] },
      created_at: Time.current,
      updated_at: Time.current
    )
  end
end
