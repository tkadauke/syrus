require "rails_helper"

RSpec.describe SyrusChatMcp::ListJobsTool do
  let!(:_bootstrap_admin) { Factories.user(admin: true) }

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, trigger_label: "syrus") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(arguments = {})
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_jobs", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "defaults to open jobs across the user's repositories with a limit of 20" do
    open_job = Factories.job(repository: repository, issue_number: 101, issue_title: "Open")
    closed_job = Factories.job(repository: repository, issue_number: 102, issue_title: "Closed")
    closed_job.close_with_reason!("pr_merged")
    other_repository = Factories.repository(user: user)
    other_repo_job = Factories.job(repository: other_repository, issue_number: 103)
    Factories.job(repository: Factories.repository, issue_number: 104)

    response = call_tool
    jobs = response_payload(response).fetch(:jobs)

    expect(response[:result][:isError]).to be_falsey
    expect(jobs.map { |job| job[:id] }).to eq([ other_repo_job.id, open_job.id ])
    expect(jobs.find { |job| job[:id] == other_repo_job.id }).to include(repository_slug: other_repository.slug)
  end

  it "filters closed jobs and caps the requested limit" do
    2.times do |i|
      job = Factories.job(repository: repository, issue_number: 200 + i)
      job.close_with_reason!("no_changes")
    end

    response = call_tool(state: "closed", limit: 1_000)
    jobs = response_payload(response).fetch(:jobs)

    expect(jobs.size).to eq(2)
    expect(jobs.all? { |job| job[:state] == "closed" }).to be(true)
  end

  it "supports persisted Syrus label filters" do
    skipped = Factories.job(repository: repository, issue_number: 301, skip_prepare: true)
    Factories.job(repository: repository, issue_number: 302)

    response = call_tool(label: Job::PREPARE_SKIP_LABEL)
    jobs = response_payload(response).fetch(:jobs)

    expect(jobs.map { |job| job[:id] }).to eq([ skipped.id ])
  end

  it "returns a tool error for labels that are not stored on Jobs" do
    response = call_tool(label: "bug")

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("label filtering only supports")
  end

  it "works without a repository pinned to the chat session" do
    chat_session.update!(repository: nil)
    job = Factories.job(repository: repository, issue_number: 401)

    response = call_tool
    jobs = response_payload(response).fetch(:jobs)

    expect(response[:result][:isError]).to be_falsey
    expect(jobs.map { |result| result[:id] }).to eq([ job.id ])
  end

  it "allows an admin to list another user's jobs" do
    admin = Factories.user(admin: true)
    other_user = Factories.user
    other_job = Factories.job(repository: Factories.repository(user: other_user), issue_number: 501)
    admin_session = ChatSession.create!(user: admin)
    admin_server = MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: admin_session }
    )

    raw = admin_server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_jobs", arguments: {} } }.to_json)
    response = JSON.parse(raw, symbolize_names: true)
    jobs = response_payload(response).fetch(:jobs)

    expect(response[:result][:isError]).to be_falsey
    expect(jobs.map { |j| j[:id] }).to include(other_job.id)
  end
end
