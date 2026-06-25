require "rails_helper"

RSpec.describe SyrusChatMcp::SearchJobsTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(arguments)
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "search_jobs", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "searches jobs across the user's repositories case-insensitively and orders by update time" do
    older = Factories.job(repository: repository, issue_title: "Repair the Aqueduct", issue_number: 10, updated_at: 2.days.ago)
    newer = Factories.job(repository: repository, issue_title: "AQUEDUCT inspection", issue_number: 11, updated_at: 1.hour.ago)
    other_repository = Factories.repository(user: user)
    elsewhere = Factories.job(repository: other_repository, issue_title: "Aqueduct elsewhere", issue_number: 12, updated_at: 30.minutes.ago)
    Factories.job(repository: Factories.repository, issue_title: "Aqueduct outsider", issue_number: 13)
    older.update_columns(updated_at: 2.days.ago)
    newer.update_columns(updated_at: 1.hour.ago)
    elsewhere.update_columns(updated_at: 30.minutes.ago)

    response = call_tool(query: "aque")
    payload = response_payload(response)

    expect(response[:result][:isError]).to be_falsey
    expect(payload.fetch(:total)).to eq(3)
    expect(payload.fetch(:results).map { |job| job[:id] }).to eq([ elsewhere.id, newer.id, older.id ])
    expect(payload.fetch(:results).find { |job| job[:id] == newer.id }).to include(
      repository_slug: repository.slug,
      kind: newer.kind,
      issue_title: "AQUEDUCT inspection",
      state: newer.state,
      pr_number: nil,
      priority: newer.priority
    )
  end

  it "searches stored issue body text when present and filters by state" do
    matching = Factories.job(repository: repository, issue_title: "Unrelated title", issue_number: 20, issue_body: "Hidden forum marble")
    closed = Factories.job(repository: repository, issue_title: "Forum marble", issue_number: 21)
    closed.close_with_reason!("no_changes")

    response = call_tool(query: "marble", state: "queued")
    results = response_payload(response).fetch(:results)

    expect(results.map { |job| job[:id] }).to eq([ matching.id ])
  end

  it "caps limit at 50" do
    55.times { |i| Factories.job(repository: repository, issue_title: "Need road #{i}", issue_number: 100 + i) }

    response = call_tool(query: "road", limit: 100)

    expect(response_payload(response).fetch(:total)).to eq(55)
    expect(response_payload(response).fetch(:results).size).to eq(50)
  end

  it "returns a tool error for short queries" do
    response = call_tool(query: "a")

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("query must be at least 2 characters")
  end

  it "works without a repository pinned to the chat session" do
    chat_session.update!(repository: nil)
    job = Factories.job(repository: repository, issue_title: "Aqueduct inspection", issue_number: 200)

    response = call_tool(query: "aque")
    results = response_payload(response).fetch(:results)

    expect(response[:result][:isError]).to be_falsey
    expect(results.map { |result| result[:id] }).to eq([ job.id ])
  end
end
