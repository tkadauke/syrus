require "rails_helper"

RSpec.describe Mcp::Tools::OperationalDiagnosticsTools do
  let(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user }
  let(:repository) { Factories.repository(user: admin) }
  let(:admin_chat) { ChatSession.create!(user: admin, repository: repository, title: "Operations") }
  let(:member_chat) { ChatSession.create!(user: member, title: "Operations") }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: admin, name: "Maya", handle: "maya", workspace_repo: repository.remote_url)
  end
  let(:coworker_chat) { ChatSession.create!(user: admin, repository: repository, title: "Maya") }
  let(:scope) { Syrus::EffectScope.new(label: "operational diagnostics tools spec") }

  let(:tool_names) do
    %w[
      read_metrics_diagnostics read_worker_occupancy read_workflow_timeline
      read_workflow_waterfall read_admission_diagnostics diagnose_run_queue
    ]
  end

  before do
    Coworkers::Chat.create!(coworker: coworker, chat_session: coworker_chat, role: "main")
    Coworkers::ChatExtension.install_into(scope)
  end

  after { scope.dispose }

  def names_for(chat)
    Mcp::Sidecar.chat_tools(chat.reload, tier: :essential).map { |tool| McpToolRegistry.tool_name_for(tool) }
  end

  def parsed(response)
    JSON.parse(response.content.first.fetch(:text))
  end

  it "uses the same canonical implementations and schemas on regular and coworker surfaces" do
    chat_entries = McpToolRegistry.entries(surface: :chat).select { |entry| tool_names.include?(entry.tool_name) }
    coworker_entries = McpToolRegistry.entries(surface: :coworker).select { |entry| tool_names.include?(entry.tool_name) }

    expect(chat_entries.map(&:tool_name)).to contain_exactly(*tool_names)
    expect(coworker_entries.map(&:tool_name)).to contain_exactly(*tool_names)
    expect(coworker_entries.index_by(&:tool_name).transform_values(&:tool))
      .to eq(chat_entries.index_by(&:tool_name).transform_values(&:tool))
    expect(coworker_entries).to all(have_attributes(capability: :"ops.read_logs", mutation: false))
  end

  it "advertises the family to admins and granted coworkers but not unauthorized chats" do
    expect(names_for(admin_chat)).to include(*tool_names)
    expect(names_for(member_chat)).not_to include(*tool_names)
    expect(names_for(coworker_chat)).not_to include(*tool_names)

    coworker.grants.create!(capability: "ops.read_logs", approval_policy: "auto")
    expect(names_for(coworker_chat)).to include(*tool_names)
  end

  it "returns the same capped, redacted, action-free admission shape across authorized surfaces" do
    coworker.grants.create!(capability: "ops.read_logs", approval_policy: "auto")
    payload = {
      generated_at: Time.current.iso8601, active_consumers: [], recent_top_consumers: [], delayed_work: [],
      low_confidence_profiles: [], admission_overrides: [], secret: "token=hidden", actions: [ "retry" ]
    }
    allow(Admin::ResourceAdmissionDiagnosticsPayload).to receive(:new)
      .and_return(instance_double(Admin::ResourceAdmissionDiagnosticsPayload, as_json: payload))

    tool = described_class::ReadAdmissionDiagnosticsTool
    regular = parsed(tool.call(server_context: { chat_session: admin_chat }))
    coworker_result = parsed(tool.call(server_context: { chat_session: coworker_chat }))

    expect(coworker_result).to eq(regular)
    expect(regular).to include("source" => "Admin::ResourceAdmissionDiagnosticsPayload", "read_only" => true)
    expect(regular.to_json).not_to include("hidden")
    expect(regular.dig("data", "actions")).to be_nil
  end

  it "rejects direct invocation without regular admin or coworker grant authority" do
    tool = described_class::ReadAdmissionDiagnosticsTool
    expect(Admin::ResourceAdmissionDiagnosticsPayload).not_to receive(:new)

    expect(tool.call(server_context: { chat_session: member_chat })).to be_error
    coworker_response = tool.call(server_context: { chat_session: coworker_chat })
    expect(parsed(coworker_response)).to include("approval_policy" => "queue", "message" => "Queued for owner approval.")
  end

  it "does not expose a Run outside the granted coworker's repository visibility" do
    hidden_repository = Factories.repository
    hidden_job = Factories.job(repository: hidden_repository)
    hidden_run = Factories.run(job: hidden_job)
    coworker.grants.create!(capability: "ops.read_logs", approval_policy: "auto")

    response = described_class::DiagnoseRunQueueTool.call(
      server_context: { chat_session: coworker_chat }, run_id: hidden_run.id
    )

    expect(response).to be_error
    expect(response.content.first.fetch(:text)).to include("not found or not visible")
  end

  it "delegates historical metrics to the existing dashboard payload" do
    allow(MetricsDashboard).to receive(:enabled?).and_return(true)
    allow(MetricsDashboard::DashboardPayload).to receive(:build).with(window: "24h").and_return(window: "24h", panels: [])

    response = described_class::ReadMetricsDiagnosticsTool.call(
      server_context: { chat_session: admin_chat }, window: "24h"
    )

    expect(parsed(response)).to include("source" => "MetricsDashboard::DashboardPayload")
    expect(MetricsDashboard::DashboardPayload).to have_received(:build).with(window: "24h")
  end

  it "passes time and host filters to the existing live occupancy query and caps workers" do
    allow(WorkerTimeline).to receive(:enabled?).and_return(true)
    allow(WorkerTimeline::LiveWorkersQuery).to receive(:call).and_return(workers: Array.new(60) { |id| { id: id } })

    response = described_class::ReadWorkerOccupancyTool.call(
      server_context: { chat_session: admin_chat }, from: "2026-10-31T10:00:00Z",
      to: "2026-10-31T11:00:00Z", hostname: "worker-a", status: [ "busy" ]
    )

    expect(WorkerTimeline::LiveWorkersQuery).to have_received(:call).with(
      from: Time.zone.parse("2026-10-31T10:00:00Z"), to: Time.zone.parse("2026-10-31T11:00:00Z"),
      hostname: "worker-a", status: [ "busy" ]
    )
    expect(parsed(response).dig("data", "workers").size).to eq(50)
  end

  it "removes occupancy details and derived counts outside a granted coworker's attached repositories" do
    visible_job = Factories.job(repository: repository)
    hidden_job = Factories.job(repository: Factories.repository)
    coworker.grants.create!(capability: "ops.read_logs", approval_policy: "auto")
    allow(WorkerTimeline).to receive(:enabled?).and_return(true)
    allow(WorkerTimeline::LiveWorkersQuery).to receive(:call).and_return(
      summary: { busy: 1, used_slots: 2, total_slots: 2 },
      diagnostics: { stale_terminal_descendants: [
        { job_id: visible_job.id, job_title: "Visible stale" },
        *Array.new(100) { |index| { job_id: visible_job.id, run_id: index } },
        { job_id: hidden_job.id, job_title: "Hidden stale", command: "hidden stale command" }
      ] },
      workers: [ {
        status: "busy", capacity_exceeded: false,
        occupancy: { used: 2, total: 2, slots: 2 },
        pools: [ { capacity: 2, used: 2, status: "busy", slots: [
          { id: "visible", attribution: "run", run_id: 1, job_id: visible_job.id, job_title: "Visible" },
          { id: "hidden", attribution: "run", run_id: 2, job_id: hidden_job.id, job_title: "Hidden", command: "secret command" }
        ] } ]
      } ]
    )

    response = described_class::ReadWorkerOccupancyTool.call(server_context: { chat_session: coworker_chat })

    data = parsed(response).fetch("data")
    slots = data.dig("workers", 0, "pools", 0, "slots")
    expect(slots).to contain_exactly(include("job_id" => visible_job.id, "job_title" => "Visible"))
    stale_descendants = data.dig("diagnostics", "stale_terminal_descendants")
    expect(stale_descendants.size).to eq(100)
    expect(stale_descendants).to include(include("job_id" => visible_job.id, "job_title" => "Visible stale"))
    expect(data.dig("workers", 0, "occupancy")).to eq("used" => 1, "total" => 2, "slots" => 1)
    expect(data.fetch("summary")).to include("used_slots" => 1, "total_slots" => 2, "busy" => 1)
    expect(response.content.first.fetch(:text)).not_to include("Hidden", "hidden stale", "secret command")
  end

  it "rejects inverted and oversized timeline ranges before querying" do
    allow(WorkerTimeline).to receive(:enabled?).and_return(true)
    allow(WorkerTimeline::LiveWorkersQuery).to receive(:call)

    inverted = described_class::ReadWorkerOccupancyTool.call(
      server_context: { chat_session: admin_chat }, from: "2026-10-31T11:00:00Z", to: "2026-10-31T10:00:00Z"
    )
    oversized = described_class::ReadWorkflowTimelineTool.call(
      server_context: { chat_session: admin_chat }, from: "2026-10-01T10:00:00Z", to: "2026-10-31T10:00:00Z"
    )

    expect(inverted.content.first.fetch(:text)).to include("from must be before to")
    expect(oversized.content.first.fetch(:text)).to include("time range cannot exceed 7 days")
    expect(WorkerTimeline::LiveWorkersQuery).not_to have_received(:call)
  end

  it "passes repository and Job filters plus the caller's visibility scope to the macro query" do
    allow(WorkerTimeline).to receive(:enabled?).and_return(true)
    allow(Timeline::MacroQuery).to receive(:call).and_return(lanes: [], pending: [])

    described_class::ReadWorkflowTimelineTool.call(
      server_context: { chat_session: admin_chat }, repository_id: repository.id, job_id: 123, hostname: "worker-a"
    )

    expect(Timeline::MacroQuery).to have_received(:call) do |arguments|
      expect(arguments).to include(repository_id: repository.id, job_id: 123, hostname: "worker-a")
      expect(arguments.fetch(:allowed_job_ids)).to be_an(ActiveRecord::Relation)
    end
  end

  it "limits coworker timelines, waterfalls, Runs, and admission rows to attached repositories" do
    visible_job = Factories.job(repository: repository)
    hidden_job = Factories.job(repository: Factories.repository)
    hidden_workflow = hidden_job.workflows.first
    hidden_run = Factories.run(job: hidden_job)
    coworker.grants.create!(capability: "ops.read_logs", approval_policy: "auto")
    allow(WorkerTimeline).to receive(:enabled?).and_return(true)
    allow(Timeline::MacroQuery).to receive(:call).and_return(lanes: [], pending: [])
    allow(Admin::ResourceAdmissionDiagnosticsPayload).to receive(:new).and_return(
      instance_double(Admin::ResourceAdmissionDiagnosticsPayload, as_json: {
        active_consumers: [ { job_id: visible_job.id }, { job_id: hidden_job.id } ],
        recent_top_consumers: [], delayed_work: [], low_confidence_profiles: [], admission_overrides: []
      })
    )

    described_class::ReadWorkflowTimelineTool.call(server_context: { chat_session: coworker_chat })
    allowed_ids = nil
    expect(Timeline::MacroQuery).to have_received(:call) { |args| allowed_ids = args.fetch(:allowed_job_ids).pluck(:id) }
    expect(allowed_ids).to contain_exactly(visible_job.id)
    expect(described_class::ReadWorkflowWaterfallTool.call(server_context: { chat_session: coworker_chat }, workflow_id: hidden_workflow.id)).to be_error
    expect(described_class::DiagnoseRunQueueTool.call(server_context: { chat_session: coworker_chat }, run_id: hidden_run.id)).to be_error

    admission = parsed(described_class::ReadAdmissionDiagnosticsTool.call(server_context: { chat_session: coworker_chat }))
    expect(admission.dig("data", "active_consumers")).to eq([ { "job_id" => visible_job.id } ])
  end

  it "delegates a visible queued Run to the existing queue diagnosis" do
    job = Factories.job(repository: repository)
    run = Factories.run(job: job)
    allow(RunQueueDiagnosis).to receive(:call).with(run).and_return(kind: "ready_waiting_for_slot", details: {})

    response = described_class::DiagnoseRunQueueTool.call(server_context: { chat_session: admin_chat }, run_id: run.id)

    expect(parsed(response).dig("data", "diagnosis", "kind")).to eq("ready_waiting_for_slot")
  end
end
