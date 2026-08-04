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
    "admin_retry_step" => { workflow_id: 1, step_slug: "implement", reason: "Retry the failed implement step." },
    "admin_cleanup_workspace" => { workflow_id: 1, reason: "Free an abandoned workspace." },
    "admin_refresh_installations" => {},
    "admin_github_app_installation_diagnostic" => {},
    "force_fail_job" => { job_id: 1, reason: "Mark a stuck running job failed." },
    "reconcile_job_state" => { job_id: 1, mode: "auto", reason: "Repair state drift." },
    "force_state_transition" => { job_id: 1, event: "force_fail", reason: "Repair state drift." },
    "cancel_stale_work" => { job_id: 1, reason: "Cancel stale work." },
    "reenqueue_work" => { job_id: 1, reason: "Re-enqueue queued work." },
    "force_rebase" => { job_id: 1, reason: "Bypass the landing queue proximity guard." },
    "restack_epic" => { epic_id: 1, reason: "Repair stale stack topology." },
    "force_landing_recheck" => { job_id: 1, reason: "Refresh stale landing metadata." },
    "override_landing_blocker_once" => { job_id: 1, blocker_key: "active_workflow", reason: "Verified blocker is stale." },
    "wake_landing_queue" => { reason: "Repair completed." }
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
    workflow.job.update_columns(state: "approved", pr_number: 99, auto_merge_enabled: true, approved_at: 1.minute.ago)
    workflow.job.update_columns(branch_name: "syrus/direct-#{workflow.job.id}")
    epic = Factories.epic(user: admin, repository: repository)
    Factories.job_record(user: admin, repository: repository, epic: epic, state: "approved", branch_name: "syrus/epic-#{epic.id}-child", pr_number: 77)

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
      "admin_retry_step" => [ { workflow_id: workflow.id, step_slug: "implement", reason: "Retry the failed step." }, { "workflow_id" => workflow.id, "step_slug" => "implement" } ],
      "admin_cleanup_workspace" => [ { workflow_id: workflow.id, reason: "Remove stale workspace files." }, { "workflow_id" => workflow.id } ],
      "admin_refresh_installations" => [ {}, {} ],
      "force_fail_job" => [ { job_id: workflow.job.id, reason: "Operator determined it is stuck." }, { "job_id" => workflow.job.id, "previous_state" => workflow.job.state } ],
      "reconcile_job_state" => [ { job_id: workflow.job.id, mode: "auto", reason: "Run targeted state repair." }, { "job_id" => workflow.job.id, "mode" => "auto" } ],
      "force_state_transition" => [ { job_id: workflow.job.id, event: "force_fail", reason: "Apply a constrained state transition." }, { "job_id" => workflow.job.id, "event" => "force_fail" } ],
      "cancel_stale_work" => [ { job_id: workflow.job.id, workflow_ids: [ workflow.id ], run_ids: [ workflow.runs.first.id ], reason: "Cancel stale work." }, { "job_id" => workflow.job.id, "workflow_ids" => [ workflow.id ], "run_ids" => [ workflow.runs.first.id ], "reconcile" => true } ],
      "reenqueue_work" => [ { job_id: workflow.job.id, run_id: workflow.runs.first.id, reason: "Re-enqueue queued work." }, { "job_id" => workflow.job.id, "workflow_id" => nil, "run_id" => workflow.runs.first.id } ],
      "force_rebase" => [ { job_id: workflow.job.id, reason: "Bypass the landing queue proximity guard." }, { "job_id" => workflow.job.id, "bypass_front_of_queue" => true } ],
      "restack_epic" => [ { epic_id: epic.id, reason: "Repair stale stack topology." }, { "epic_id" => epic.id, "strategy" => "dependency_topology" } ],
      "force_landing_recheck" => [ { job_id: workflow.job.id, reason: "Refresh stale landing metadata." }, { "job_id" => workflow.job.id } ],
      "override_landing_blocker_once" => [ { job_id: workflow.job.id, blocker_key: "active_workflow", reason: "Verified blocker is stale." }, { "job_id" => workflow.job.id, "blocker_key" => "active_workflow" } ],
      "wake_landing_queue" => [ { reason: "Repair completed." }, { "reason" => "Repair completed." } ]
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
        requested_by: "agent"
      )
      expect(action.payload).to include(expected_payload)
      expect(action.reason).to be_present if name.in?(%w[admin_retry_step admin_cleanup_workspace force_fail_job reconcile_job_state force_state_transition cancel_stale_work reenqueue_work force_rebase restack_epic force_landing_recheck override_landing_blocker_once wake_landing_queue])
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

  it "confirms wake_landing_queue by enqueueing the processor" do
    response = call_tool(admin_session, "wake_landing_queue", { reason: "Retry after metadata repair." })
    action = ChatPendingAction.find(payload_for(response).fetch(:pending_confirmation_id))

    expect {
      expect(action.confirm!).to be true
    }.to have_enqueued_job(LandingQueueProcessorJob)
  end

  it "returns force_rebase dry-run output without creating a pending action" do
    job = Factories.job_record(
      user: admin,
      repository: repository,
      state: "approved",
      branch_name: "syrus/direct-2265",
      pr_number: 2265,
      commits_behind_base: 2,
      pr_checks_state: "failure",
      github_mergeable_state: "dirty",
      landing_queue_position: 4
    )

    response = call_tool(admin_session, "force_rebase", { job_id: job.id, dry_run: true })
    plan = payload_for(response).fetch(:plan)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(plan).to include(
      job_id: job.id,
      pr_number: 2265,
      commits_behind: 2,
      workflow_trigger_kind: "rebase",
      expected_landing_impact: "successful rebase will retry landing immediately"
    )
    expect(plan.fetch(:warnings)).to include("failing_or_pending_checks", "dirty_mergeability", "behind_base", "not_front_of_queue")
    expect(admin_session.pending_actions.where(action: "force_rebase")).to be_empty
  end

  it "confirms force_rebase by dispatching a rebase workflow with audit snapshots" do
    job = Factories.job_record(user: admin, repository: repository, state: "approved", branch_name: "syrus/direct-2265", pr_number: 2265)
    allow(StepDispatcher).to receive(:start_workflow)

    response = call_tool(admin_session, "force_rebase", { job_id: job.id, reason: "Bypass queue position." })
    action = ChatPendingAction.find(payload_for(response).fetch(:pending_confirmation_id))

    expect {
      expect(action.confirm!).to be true
    }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)

    workflow = action.reload.result
    expect(workflow).to have_attributes(job: job, trigger_kind: "rebase")
    expect(workflow.artifact("repair_action")).to eq("force_rebase")
    expect(StepDispatcher).to have_received(:start_workflow).with(workflow)
    expect(action.before_snapshot).to include("jobs")
    expect(action.after_snapshot).to include("jobs")
  end

  it "returns restack_epic dry-run output with planned order and skipped nodes" do
    epic = Factories.epic(user: admin, repository: repository)
    root = Factories.job_record(user: admin, repository: repository, epic: epic, issue_number: 31, state: "approved", branch_name: "syrus/root", pr_number: 31)
    child = Factories.job_record(user: admin, repository: repository, epic: epic, issue_number: 32, state: "approved", branch_name: "syrus/child", pr_number: 32)
    closed = Factories.job_record(user: admin, repository: repository, epic: epic, issue_number: 33, state: "closed", branch_name: "syrus/closed", pr_number: 33)
    JobDependency.create!(job: child, depends_on_job: root, source: "manual")

    response = call_tool(admin_session, "restack_epic", { epic_id: epic.id, dry_run: true })
    plan = payload_for(response).fetch(:plan)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(plan.fetch(:branch_order).map { |entry| entry.fetch(:job_id) }).to eq([ root.id, child.id ])
    expect(plan.fetch(:branch_order).map { |entry| entry.fetch(:target_base) }).to eq([ repository.default_branch, root.branch_name ])
    expect(plan.fetch(:skipped_nodes)).to include(hash_including(job_id: closed.id, reason: "closed"))
    expect(admin_session.pending_actions.where(action: "restack_epic")).to be_empty
  end

  it "confirms restack_epic by updating stack parents and dispatching stack rebase" do
    epic = Factories.epic(user: admin, repository: repository)
    root = Factories.job_record(user: admin, repository: repository, epic: epic, issue_number: 41, state: "approved", branch_name: "syrus/root", pr_number: 41)
    child = Factories.job_record(user: admin, repository: repository, epic: epic, issue_number: 42, state: "approved", branch_name: "syrus/child", pr_number: 42)
    JobDependency.create!(job: child, depends_on_job: root, source: "manual")
    allow(StepDispatcher).to receive(:start_workflow)

    response = call_tool(admin_session, "restack_epic", { epic_id: epic.id, reason: "Repair stale stack topology." })
    action = ChatPendingAction.find(payload_for(response).fetch(:pending_confirmation_id))

    expect {
      expect(action.confirm!).to be true
    }.to change { root.workflows.where(trigger_kind: "stack_rebase").count }.by(1)

    expect(child.reload.parent_job).to eq(root)
    workflow = action.reload.result
    expect(workflow).to have_attributes(job: root, trigger_kind: "stack_rebase")
    expect(workflow.artifact("repair_action")).to eq("restack_epic")
    expect(workflow.artifact(StackRebasePlan::STACK_ARTIFACT).map { |entry| entry["job_id"] }).to eq([ root.id, child.id ])
    expect(StepDispatcher).to have_received(:start_workflow).with(workflow)
  end

  it "confirms force_landing_recheck through the recheck service" do
    job = Factories.job_record(user: admin, repository: repository, state: "approved", pr_number: 42)
    result = LandingQueueRecheck::Result.new(
      job: job,
      pr_refreshed: true,
      checks_refreshed: true,
      commits_behind_refreshed: true,
      queue_entry: nil,
      warnings: []
    )
    allow(LandingQueueRecheck).to receive(:call).with(job).and_return(result)

    response = call_tool(admin_session, "force_landing_recheck", { job_id: job.id, reason: "Refresh stale metadata." })
    action = ChatPendingAction.find(payload_for(response).fetch(:pending_confirmation_id))

    expect(action.confirm!).to be true
    expect(LandingQueueRecheck).to have_received(:call).with(job)
    expect(action.reload.before_snapshot).to include("jobs")
    expect(action.after_snapshot).to include("jobs")
  end

  it "confirms override_landing_blocker_once only for the observed blocker" do
    job = Factories.job_record(user: admin, repository: repository, state: "implemented", pr_number: 42)
    job.approve!(via: "operator")
    job.update!(auto_merge_enabled: true)
    admin.update!(landing_paused: true)

    response = call_tool(
      admin_session,
      "override_landing_blocker_once",
      { job_id: job.id, blocker_key: "landing_paused", reason: "Verified queue pause was stale." }
    )
    action = ChatPendingAction.find(payload_for(response).fetch(:pending_confirmation_id))

    expect {
      expect(action.confirm!).to be true
    }.to have_enqueued_job(LandingQueueProcessorJob)

    expect(job.reload).to have_attributes(
      landing_blocker_override_key: "landing_paused",
      landing_blocker_override_reason: "Verified queue pause was stale.",
      landing_blocker_override_requested_by_user_id: admin.id,
      landing_blocker_override_used_at: nil
    )
  end

  it "rejects override_landing_blocker_once when the current blocker changed before confirmation" do
    job = Factories.job_record(user: admin, repository: repository, state: "implemented", pr_number: 42)
    job.approve!(via: "operator")
    job.update!(auto_merge_enabled: true)
    admin.update!(landing_paused: true)

    action = ChatPendingAction.create!(
      chat_session: admin_session,
      user: admin,
      repository: repository,
      action: "override_landing_blocker_once",
      payload: { "job_id" => job.id, "blocker_key" => "landing_paused" },
      reason: "Verified queue pause was stale.",
      requested_by: "agent",
      state: "pending"
    )
    admin.update!(landing_paused: false)

    expect { action.confirm! }.to raise_error(ArgumentError, /Current blocker is none/)
    expect(job.reload.landing_blocker_override_key).to be_nil
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
