require "rails_helper"

RSpec.describe "Coworker Job visibility across user-facing paths", type: :request do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:owner) { Factories.user }
  let(:member) { Factories.user }
  let(:repository_admin) { Factories.user }
  let(:instance_admin) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: owner, owner: "acme", name: "coworker-visibility") }
  let!(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner,
      name: "Maya",
      handle: "maya-path-visibility",
      workspace_repo: repository.remote_url
    )
  end
  let!(:task) do
    Factories.job_record(
      repository: repository,
      owner_user: owner,
      origin: "coworkers",
      origin_id: coworker.id.to_s,
      issue_title: "Coworker visibility needle"
    )
  end

  before do
    repository.repository_memberships.create!(user: member, role: "read")
    repository.repository_memberships.create!(user: repository_admin, role: "admin")
    repository.repository_memberships.create!(user: instance_admin, role: "read")
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
    prepare_search_table
    GlobalSearch::JobIndex.upsert(task)
    sign_in_as(actor)
  end

  shared_examples "coworker Job path visibility" do
    it "applies the owner-only rule to the Jobs API, global search, MCP scopes, and dashboard queries" do
      get "/api/v1/app/jobs", params: { include_active_work: true }
      expect(response).to have_http_status(:ok)
      jobs_api = JSON.parse(response.body)
      expect(jobs_api.fetch("count")).to eq(expected_visible ? 1 : 0)
      expect(jobs_api.fetch("jobs").map { |job| job.fetch("id") }.include?(task.id)).to eq(expected_visible)

      get "/api/v1/app/search", params: { query: "visibility needle", types: [ "job" ] }
      expect(response).to have_http_status(:ok)
      search_results = JSON.parse(response.body).fetch("results")
      expect(search_results.size).to eq(expected_visible ? 1 : 0)
      expect(search_results.map { |job| job.fetch("id") }.include?(task.id)).to eq(expected_visible)

      listed_jobs = mcp_payload(Mcp::Tools::ListJobsTool, {}).fetch(:jobs)
      expect(listed_jobs.map { |job| job.fetch(:id) }.include?(task.id)).to eq(expected_visible)

      searched_jobs = mcp_payload(Mcp::Tools::SearchJobsTool, query: "visibility needle")
      expect(searched_jobs.fetch(:total)).to eq(expected_visible ? 1 : 0)
      expect(searched_jobs.fetch(:results).map { |job| job.fetch(:id) }.include?(task.id)).to eq(expected_visible)

      get "/api/v1/app/dashboard",
          params: { subject: "job", view: "list", scope: "team", smart_folder_id: "" }
      expect(response).to have_http_status(:ok)
      dashboard = JSON.parse(response.body)
      expect(dashboard.fetch("total")).to eq(expected_visible ? 1 : 0)
      expect(dashboard.dig("counts", "jobs")).to eq(expected_visible ? 1 : 0)
      expect(dashboard.fetch("items").map { |job| job.fetch("id") }.include?(task.id)).to eq(expected_visible)
    end
  end

  context "as the coworker owner" do
    let(:actor) { owner }
    let(:expected_visible) { true }

    include_examples "coworker Job path visibility"
  end

  context "as another member of the shared repository" do
    let(:actor) { member }
    let(:expected_visible) { false }

    include_examples "coworker Job path visibility"
  end

  context "as a repository administrator" do
    let(:actor) { repository_admin }
    let(:expected_visible) { false }

    include_examples "coworker Job path visibility"
  end

  context "as an instance administrator" do
    let(:actor) { instance_admin }
    let(:expected_visible) { true }

    include_examples "coworker Job path visibility"
  end

  def mcp_payload(tool, arguments)
    chat = ChatSession.create!(user: actor, repository: repository)
    server = MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ tool ],
      server_context: { chat_session: chat }
    )
    raw = server.handle_json(
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: tool.tool_name, arguments: arguments } }.to_json
    )
    response = JSON.parse(raw, symbolize_names: true)

    expect(response.dig(:result, :isError)).to be_falsey
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  def prepare_search_table
    SearchRecord.connection.execute("DROP TABLE IF EXISTS job_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE job_fts
      USING fts5(
        title,
        body,
        job_id UNINDEXED,
        user_id UNINDEXED,
        repository_id UNINDEXED,
        state UNINDEXED,
        created_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
  end
end
