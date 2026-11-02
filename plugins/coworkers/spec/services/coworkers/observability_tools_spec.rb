require "rails_helper"

RSpec.describe "Coworker observability tools" do
  let(:owner) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url)
  end
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }
  let(:scope) { Syrus::EffectScope.new(label: "coworker observability spec") }

  before do
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    Coworkers::ChatExtension.install_into(scope)
    allow(SyrusVersion).to receive(:current).and_return("current-sha")
  end

  after { scope.dispose }

  def family
    McpToolRegistry.entries(surface: :coworker).select { |entry| entry.capability == :"ops.read_logs" }
  end

  def advertised_names
    Mcp::Sidecar.chat_tools(chat.reload, tier: :essential).map { |tool| McpToolRegistry.tool_name_for(tool) }
  end

  def payload(response)
    JSON.parse(response.content.first.fetch(:text))
  end

  it "advertises the shared read-only observability tools only with the grant" do
    expected = %w[
      admin_read_operational_logs read_worker_health read_backend_exception_events
      read_browser_error_events read_performance_log_events read_metrics_diagnostics
      read_worker_occupancy read_workflow_timeline read_workflow_waterfall
      read_admission_diagnostics diagnose_run_queue
    ]

    expect(family.map(&:tool_name)).to contain_exactly(*expected)
    expect(family).to all(be_read_only)
    expect(Coworkers::GrantCatalog.fetch("ops.read_logs")).to have_attributes(
      default_policy: "confirm", maximum_policy: "auto", tools: contain_exactly(*expected)
    )
    expect(advertised_names).not_to include(*expected)

    coworker.grants.create!(capability: "ops.read_logs", approval_policy: "auto")

    expect(advertised_names & expected).to contain_exactly(*expected)
  end

  it "allows every family tool and keeps event output capped, redacted, and action-free" do
    coworker.grants.create!(capability: "ops.read_logs", approval_policy: "auto")
    context = { chat_session: chat }
    allow(OperationalLogging).to receive(:enabled_for_instance?).and_return(true)
    allow(OperationalLogSearch).to receive(:search_response).and_return(Mcp::Tools.success(logs: []))
    allow(Admin::WorkerHealthPayload).to receive(:new).and_return(instance_double(Admin::WorkerHealthPayload, as_json: { workers: [] }))

    101.times do |index|
      BackendExceptionEvent.create!(
        occurred_at: index.seconds.ago, app_revision: "current-sha", source: "active_job",
        exception_class: "RuntimeError", message: "api_key=super-secret-#{index}"
      )
    end
    BrowserErrorEvent.record!(user: owner, payload: {
      occurred_at: Time.current.iso8601, app_revision: "current-sha", fingerprint: "browser",
      message: "token=browser-secret", path: "/jobs"
    })
    PerformanceLogging::Store.append(
      "event" => PerformanceLogging::SLOW_REQUEST_EVENT, "occurred_at" => Time.current.iso8601,
      "app_revision" => "current-sha", "duration_ms" => 123, "path" => "/jobs?token=perf-secret"
    )

    responses = {
      logs: Mcp::Tools::AdminReadOperationalLogsTool.call(server_context: context),
      workers: Mcp::Tools::ReadWorkerHealthTool.call(server_context: context),
      backend: Mcp::Tools::ReadBackendExceptionEventsTool.call(server_context: context, revision_scope: "current", limit: 500),
      browser: Mcp::Tools::ReadBrowserErrorEventsTool.call(server_context: context, revision_scope: "current"),
      performance: Mcp::Tools::ReadPerformanceLogEventsTool.call(server_context: context)
    }

    expect(responses.values).to all(satisfy { |response| !response.error? })
    backend = payload(responses.fetch(:backend))
    expect(backend.fetch("events").size).to eq(100)
    expect(backend.to_json).not_to include("super-secret", '"actions"')
    expect(payload(responses.fetch(:browser)).to_json).not_to include("browser-secret", '"actions"')
    expect(payload(responses.fetch(:performance)).to_json).not_to include("perf-secret")
  end

  it "filters the retained performance window before applying the result limit" do
    coworker.grants.create!(capability: "ops.read_logs", approval_policy: "auto")
    newer_events = 2.times.map do |index|
      {
        "event" => PerformanceLogging::SLOW_REQUEST_EVENT,
        "occurred_at" => index.seconds.ago.iso8601,
        "app_revision" => "current-sha",
        "request_id" => "newer-#{index}"
      }
    end
    matching_event = {
      "event" => PerformanceLogging::SLOW_REQUEST_EVENT,
      "occurred_at" => 3.seconds.ago.iso8601,
      "app_revision" => "current-sha",
      "request_id" => "target-request"
    }
    allow(PerformanceLogging::Store).to receive(:recent).with(no_args).and_return(newer_events + [ matching_event ])

    response = Mcp::Tools::ReadPerformanceLogEventsTool.call(
      server_context: { chat_session: chat }, request_id: "target-request", limit: 1
    )

    expect(response).not_to be_error
    expect(payload(response).fetch("events")).to contain_exactly(include("request_id" => "target-request"))
  end
end
