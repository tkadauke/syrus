require "rails_helper"

RSpec.describe SyrusChatMcp::ListRepositoriesTool do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(arguments = {})
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_repositories", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "returns only the current user's active repositories" do
    beta = Factories.repository(user: user, owner: "acme", name: "beta", default_branch: "main")
    alpha = Factories.repository(user: user, owner: "acme", name: "alpha", default_branch: "trunk")
    Factories.repository(user: Factories.user, owner: "acme", name: "foreign")

    response = call_tool
    payload = response_payload(response)
    repositories = payload.fetch(:repositories)

    expect(response[:result][:isError]).to be_falsey
    expect(repositories.map { |repository| repository[:id] }).to eq([ alpha.id, beta.id ])
    expect(repositories.first).to include(
      id: alpha.id,
      slug: "acme/alpha",
      owner: "acme",
      name: "alpha",
      default_branch: "trunk"
    )
    expect(repositories.first[:created_at]).to be_present
  end

  it "returns correct pagination metadata" do
    25.times do |i|
      Factories.repository(user: user, owner: "acme", name: format("repo-%02d", i))
    end

    first_page = response_payload(call_tool(page: 1, per_page: 10))
    third_page = response_payload(call_tool(page: 3, per_page: 10))

    expect(first_page.fetch(:repositories).size).to eq(10)
    expect(first_page.fetch(:pagination)).to include(
      page: 1,
      per_page: 10,
      total_count: 25,
      total_pages: 3,
      has_next_page: true
    )

    expect(third_page.fetch(:repositories).size).to eq(5)
    expect(third_page.fetch(:pagination)).to include(
      page: 3,
      per_page: 10,
      total_count: 25,
      total_pages: 3,
      has_next_page: false
    )
  end

  it "clamps per_page to 100" do
    101.times do |i|
      Factories.repository(user: user, owner: "acme", name: format("repo-%03d", i))
    end

    payload = response_payload(call_tool(per_page: 1_000))

    expect(payload.fetch(:repositories).size).to eq(100)
    expect(payload.fetch(:pagination)).to include(
      page: 1,
      per_page: 100,
      total_count: 101,
      total_pages: 2,
      has_next_page: true
    )
  end

  it "excludes archived repositories" do
    active = Factories.repository(user: user, owner: "acme", name: "active")
    archived = Factories.repository(user: user, owner: "acme", name: "archived")
    archived.archive!

    payload = response_payload(call_tool)
    repositories = payload.fetch(:repositories)

    expect(repositories.map { |repository| repository[:id] }).to eq([ active.id ])
    expect(payload.fetch(:pagination)).to include(
      total_count: 1,
      total_pages: 1,
      has_next_page: false
    )
  end
end
