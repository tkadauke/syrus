require "rails_helper"

RSpec.describe "investigation workflow lookup tools" do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository_owner) { Factories.user }
  let(:repository) { Factories.repository(user: repository_owner, owner: "acme", name: "widgets") }
  let(:source_job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Investigate widget duplicates",
      issue_body: "Check whether the widget findings are already tracked.",
      investigation: true
    )
  end
  let(:workflow) { Workflows::Investigation.instantiate(job: source_job) }
  let(:run) do
    step = workflow.steps.find_by!(kind: "investigate")
    step.runs.create!(job: source_job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
  end

  before do
    repository.repository_memberships.create!(user: user, role: "read")
  end

  def server_for(context_run)
    Mcp::Sidecar.workflow(run_id: context_run.id).build_server
  end

  def jsonrpc(server, method, id: 1, params: {})
    raw = server.handle_json({ jsonrpc: "2.0", id: id, method: method, params: params }.to_json)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  def sql_queries
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:name] == "SCHEMA"

      queries << payload[:sql].to_s
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  it "advertises read-only lookup tools for investigate and submit_report steps" do
    server = server_for(run)

    response = jsonrpc(server, "tools/list")
    tools = response.dig(:result, :tools).index_by { |tool| tool[:name] }
    lookup_names = %w[search_jobs list_jobs list_open_prs read_pr list_open_issues]

    expect(tools.keys).to include(*lookup_names)
    lookup_names.each do |name|
      entry = McpToolRegistry.entries(surface: :workflow).find { |candidate| candidate.tool_name == name }
      expect(entry).to be_read_only
      expect(entry.capability).to eq(:investigation_lookup)
    end

    submit_report_step = workflow.steps.find_by!(kind: "submit_report")
    submit_report_run = submit_report_step.runs.create!(
      job: source_job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider
    )
    submit_report_tools = jsonrpc(server_for(submit_report_run), "tools/list").dig(:result, :tools).map { |tool| tool[:name] }
    expect(submit_report_tools).to include("search_jobs", "list_open_prs", "read_pr", "list_open_issues")
  end

  it "does not advertise investigation lookup tools for a normal implement step" do
    implement_run = Factories.job.initial_run
    response = jsonrpc(server_for(implement_run), "tools/list")

    expect(response.dig(:result, :tools).map { |tool| tool[:name] }).not_to include(
      "search_jobs",
      "list_jobs",
      "list_open_prs",
      "read_pr",
      "list_open_issues"
    )
  end

  it "searches only Jobs in the run repository that the Job user can access" do
    matching = Factories.job_record(
      user: user,
      repository: repository,
      issue_title: "Widget marker already tracked",
      issue_number: nil,
      kind: "direct"
    )
    accessible_other_repo = Factories.repository(user: user)
    Factories.job_record(
      user: user,
      repository: accessible_other_repo,
      issue_title: "Widget marker in another accessible repo",
      issue_number: nil,
      kind: "direct"
    )
    hidden_repo = Factories.repository
    Factories.job_record(
      repository: hidden_repo,
      issue_title: "Widget marker in hidden repo",
      issue_number: nil,
      kind: "direct"
    )

    response = jsonrpc(server_for(run), "tools/call", params: {
      name: "search_jobs",
      arguments: { query: "marker" }
    })
    results = response_payload(response).fetch(:results)

    expect(response[:result][:isError]).to be_falsey
    expect(results.map { |job| job[:id] }).to eq([ matching.id ])
  end

  it "preloads repositories when mapping job search payloads" do
    3.times do |index|
      Factories.job_record(
        user: user,
        repository: repository,
        issue_title: "Batch marker #{index}",
        issue_number: nil,
        kind: "direct"
      )
    end

    response = nil
    queries = sql_queries do
      response = Mcp::Tools::SearchJobsTool.call(
        server_context: { run: run },
        query: "Batch marker",
        limit: 3
      )
    end
    payload = JSON.parse(response.content.first[:text], symbolize_names: true)
    repository_loads = queries.grep(/SELECT "?repositories"?\.\* FROM "?repositories"?/i)

    expect(response).not_to be_error
    expect(payload.fetch(:results).size).to eq(3)
    expect(repository_loads.size).to eq(1)
  end

  it "lists pull requests for the run repository with the run user's credentials" do
    stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls")
      .with(query: hash_including("state" => "open"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: [
          { number: 7, title: "Sharpen widget", created_at: "2026-05-03T09:00:00Z" }
        ].to_json
      )
    stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls/7")
      .with(headers: { "Authorization" => "token ghp_test_token" })
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          number: 7,
          title: "Sharpen widget",
          head: { ref: "feature/sharp" },
          base: { ref: "main" },
          mergeable: true,
          draft: false,
          created_at: "2026-05-03T09:00:00Z",
          updated_at: "2026-05-10T09:00:00Z"
        }.to_json
      )

    response = jsonrpc(server_for(run), "tools/call", params: {
      name: "list_open_prs",
      arguments: { limit: 5 }
    })

    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)[:pull_requests]).to eq([
      {
        number: 7,
        title: "Sharpen widget",
        head_ref: "feature/sharp",
        base_ref: "main",
        mergeable: true,
        draft: false,
        created_at: "2026-05-03T09:00:00Z",
        updated_at: "2026-05-10T09:00:00Z"
      }
    ])
  end

  it "rejects direct lookup tool calls from a non-investigation workflow step" do
    implement_run = Factories.job.initial_run

    response = Mcp::Tools::SearchJobsTool.call(
      server_context: { run: implement_run },
      query: "widget"
    )

    expect(response).to be_error
    expect(response.content.first[:text]).to include("not_authorized")
  end
end
