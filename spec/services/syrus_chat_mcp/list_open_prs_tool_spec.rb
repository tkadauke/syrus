require "rails_helper"

RSpec.describe Mcp::Tools::ListOpenPrsTool do
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

  it "lists GitHub PRs with refs, mergeability, draft state, and creation time through JSON-RPC" do
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

    response = jsonrpc("tools/call", params: {
      name: "list_open_prs",
      arguments: { state: "open", limit: 5 }
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

  it "distinguishes merged PRs from merely closed PRs" do
    stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls")
      .with(query: hash_including("state" => "closed"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: [
          { number: 8, title: "Merged one" },
          { number: 9, title: "Closed one" }
        ].to_json
      )
    stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls/8")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          number: 8,
          title: "Merged one",
          head: { ref: "feature/merged" },
          base: { ref: "main" },
          mergeable: nil,
          draft: false,
          created_at: "2026-05-04T09:00:00Z",
          merged_at: "2026-05-05T09:00:00Z"
        }.to_json
      )
    stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls/9")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          number: 9,
          title: "Closed one",
          head: { ref: "feature/closed" },
          base: { ref: "main" },
          mergeable: false,
          draft: true,
          created_at: "2026-05-06T09:00:00Z",
          merged_at: nil
        }.to_json
      )

    response = jsonrpc("tools/call", params: {
      name: "list_open_prs",
      arguments: { state: "merged", limit: 10 }
    })

    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)[:pull_requests].pluck(:number)).to eq([ 8 ])
  end
end
