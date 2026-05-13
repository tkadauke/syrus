require "rails_helper"

RSpec.describe SyrusChatMcp::ListOpenIssuesTool do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def jsonrpc(method, id: 1, params: {})
    raw = server.handle_json({ jsonrpc: "2.0", id: id, method: method, params: params }.to_json)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "lists GitHub issues with labels, author, creation time, and body excerpts through JSON-RPC" do
    long_body = "a" * 2_100
    stub_request(:get, "https://api.github.com/repos/acme/widgets/issues")
      .with(query: hash_including("state" => "open", "labels" => "bug"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: [
          {
            number: 12,
            title: "Button sticks",
            body: long_body,
            labels: [ { name: "bug" }, { name: "frontend" } ],
            user: { login: "ada" },
            created_at: "2026-05-01T12:00:00Z"
          },
          {
            number: 13,
            title: "This is a PR and should be filtered",
            body: "ignore me",
            labels: [],
            user: { login: "grace" },
            created_at: "2026-05-02T12:00:00Z",
            pull_request: { url: "https://api.github.com/repos/acme/widgets/pulls/13" }
          }
        ].to_json
      )

    response = jsonrpc("tools/call", params: {
      name: "list_open_issues",
      arguments: { state: "open", label: "bug", limit: 5 }
    })

    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)[:issues]).to eq([
      {
        number: 12,
        title: "Button sticks",
        labels: %w[bug frontend],
        author: "ada",
        created_at: "2026-05-01T12:00:00Z",
        body_excerpt: "a" * 2_048
      }
    ])
  end

  it "rejects unsupported states before calling GitHub" do
    response = jsonrpc("tools/call", params: {
      name: "list_open_issues",
      arguments: { state: "all" }
    })

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("state must be open or closed")
  end
end
