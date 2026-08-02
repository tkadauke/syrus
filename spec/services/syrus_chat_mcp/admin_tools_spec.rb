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
    "read_worker_health" => {},
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
    "admin_refresh_installations" => {},
    "admin_github_app_installation_diagnostic" => {},
    "force_fail_job" => { job_id: 1 }
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
      "admin_refresh_installations" => [ {}, {} ],
      "force_fail_job" => [ { job_id: workflow.job.id }, { "job_id" => workflow.job.id, "previous_state" => workflow.job.state } ]
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

  it "anchors admin pending actions to the current assistant message" do
    message = admin_session.messages.create!(role: "assistant", content: { "text" => "I can pause runs." })

    allow(AppEvents).to receive(:broadcast)
    expect(AppEvents).to receive(:broadcast) do |user:, payload:, **|
      expect(user).to eq(admin)
      expect(payload).to include(
        action: "pending_action_updated",
        chat_message_id: message.id
      )
    end

    response = SyrusChatMcp::AdminPauseRunsTool.call(
      server_context: { chat_session: admin_session, current_message: message }
    )

    expect(response).to be_a(MCP::Tool::Response)
    expect(message.reload.pending_action).to eq(admin_session.pending_actions.last)
    expect(message.pending_action).to have_attributes(action: "admin_pause_runs", state: "pending")
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
      kind: "running_run_without_live_worker_evidence",
      attention_state: "auto_repairable",
      last_heartbeat_at: run.reload.last_heartbeat_at.iso8601,
      workflow_state: "running",
      run_state: "running",
      workflow_id: workflow.id,
      run_id: run.id
    )
    expect(payload.fetch(:items).first.fetch(:repair_plan)).to include(action: "mark_worker_died")
  end

  it "returns the GitHub App installation diagnostic for admins" do
    AppSetting.current.update!(
      github_app_id: 42,
      github_app_slug: "operator-syrus",
      github_app_private_key_pem: OpenSSL::PKey::RSA.generate(2048).to_pem
    )

    response = call_tool(admin_session, "admin_github_app_installation_diagnostic", { repository: repository.slug })
    payload = payload_for(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload.fetch(:global)).to include(jwt_usable: true)
    expect(payload.fetch(:repositories).first).to include(slug: repository.slug)
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
    expect(payload).to include(:worker_health)
    expect(payload.fetch(:instances).first).to include(
      id: instance.id,
      hostname: "syrus-worker-a",
      role: "worker",
      version: "abc123",
      started_at: instance.started_at.iso8601
    )
  end

  it "returns worker health for admins with hostname filtering" do
    InstanceVersion.create!(
      hostname: "syrus-worker-a",
      role: "worker",
      version: "abc123",
      started_at: 5.minutes.ago,
      last_heartbeat_at: 10.seconds.ago
    )
    WorkerHostHealthSample.create!(
      hostname: "syrus-worker-a",
      role: "worker",
      version: "abc123",
      observed_at: 1.minute.ago,
      cpu_used_percent: 99,
      memory_used_percent: 70,
      data_root_used_percent: 60
    )

    response = call_tool(admin_session, "read_worker_health", { hostname: "syrus-worker-a", sample_limit_per_host: 1 })
    payload = payload_for(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload.fetch(:current).first).to include(
      hostname: "syrus-worker-a",
      health: include(level: "critical")
    )
    expect(payload.dig(:hosts, 0, :recent_samples).length).to eq(1)
  end

  it "returns bounded minute worker health buckets through the MCP tool" do
    travel_to Time.zone.parse("2026-07-31 12:30:30 UTC") do
      InstanceVersion.create!(
        hostname: "syrus-worker-a",
        role: "worker",
        version: "abc123",
        started_at: 5.minutes.ago,
        last_heartbeat_at: 10.seconds.ago
      )
      WorkerHostHealthSample.create!(
        hostname: "syrus-worker-a",
        role: "worker",
        version: "abc123",
        observed_at: Time.zone.parse("2026-07-31 12:30:05 UTC"),
        cpu_used_percent: 40,
        load_1m: 1.0,
        memory_used_percent: 50,
        data_root_used_percent: 60,
        cpu_pressure_some: 7,
        io_pressure_some: 8
      )

      response = call_tool(admin_session, "read_worker_health", {
                             hostname: "syrus-worker-a",
                             minute_bucket_window_minutes: 2,
                             sample_limit_per_host: 0
                           })
      payload = payload_for(response)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(payload.fetch(:minute_bucket)).to include(
        granularity_seconds: 60,
        window_minutes: 2,
        max_window_minutes: 1440
      )
      expect(payload.dig(:hosts, 0, :recent_samples)).to eq([])
      buckets = payload.dig(:hosts, 0, :minute_buckets)
      expect(buckets.map { |bucket| bucket[:minute] }).to eq(
        [
          "2026-07-31T12:29:00Z",
          "2026-07-31T12:30:00Z"
        ]
      )
      expect(buckets.last).to include(
        sample_count: 1,
        cpu_used_percent: { avg: 40.0, max: 40.0 },
        memory_used_percent: { avg: 50.0, max: 50.0 },
        data_root_used_percent: { avg: 60.0, max: 60.0 },
        cpu_pressure_some: { avg: 7.0, max: 7.0 },
        io_pressure_some: { avg: 8.0, max: 8.0 }
      )
    end
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
