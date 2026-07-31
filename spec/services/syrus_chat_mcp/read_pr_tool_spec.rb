require "rails_helper"

RSpec.describe Mcp::Tools::ReadPrTool do
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

  def call_tool(arguments)
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "read_pr", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "fetches PR metadata and a capped diff through GithubClient" do
    pr_url = "https://api.github.com/repos/acme/widgets/pulls/7"
    diff = "diff --git a/a.txt b/a.txt\n" + ("+x\n" * 20_000)
    metadata_stub = stub_request(:get, pr_url)
      .with(headers: { "Authorization" => "token ghp_test_token", "Accept" => "application/vnd.github.v3+json" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: {
        number: 7,
        title: "Mend the forum",
        body: "The marble is making decisions again.",
        state: "open",
        html_url: "https://github.com/acme/widgets/pull/7"
      }.to_json)
    diff_stub = stub_request(:get, pr_url)
      .with(headers: { "Authorization" => "token ghp_test_token", "Accept" => "application/vnd.github.v3.diff" })
      .to_return(status: 200, headers: { "Content-Type" => "text/plain" }, body: diff)

    response = call_tool(pr_number: 7)
    payload = response_payload(response).fetch(:pr)

    expect(response[:result][:isError]).to be_falsey
    expect(payload).to include(number: 7, title: "Mend the forum", state: "open")
    expect(payload[:diff]).to include(truncated: true, bytes: diff.bytesize)
    expect(payload[:diff][:text].bytesize).to eq(Prompts::PullRequestSummary::MAX_DIFF_BYTES)
    expect(metadata_stub).to have_been_requested
    expect(diff_stub).to have_been_requested
  end

  it "returns a tool error when GitHub cannot find the PR" do
    stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls/404")
      .to_return(status: 404, headers: { "Content-Type" => "application/json" }, body: { message: "Not Found" }.to_json)

    response = call_tool(pr_number: 404)

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("pull request not found")
  end
end
