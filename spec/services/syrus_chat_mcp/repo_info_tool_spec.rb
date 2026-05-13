require "rails_helper"

RSpec.describe SyrusChatMcp::RepoInfoTool do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "trunk", trigger_label: "syrus") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(arguments = {})
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "repo_info", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "returns repository metadata from GithubClient" do
    client = instance_double(GithubClient)
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    allow(client).to receive(:repo_info).with("acme/widgets", default_branch: "trunk").and_return(
      default_branch: "trunk",
      recent_commits: [
        { sha: "abc123", subject: "Polish the tablets" }
      ],
      branches: [
        { name: "trunk", sha: "abc123" },
        { name: "syrus/issue-1", sha: "def456" }
      ]
    )

    response = call_tool
    payload = response_payload(response).fetch(:repository)

    expect(response[:result][:isError]).to be_falsey
    expect(payload).to include(slug: "acme/widgets", default_branch: "trunk", trigger_label: "syrus", agent_provider: "claude")
    expect(payload[:recent_commits]).to contain_exactly(include(sha: "abc123", subject: "Polish the tablets"))
    expect(payload[:branches]).to contain_exactly(include(name: "trunk", sha: "abc123"), include(name: "syrus/issue-1", sha: "def456"))
  end

  it "returns a tool error when GithubClient cannot authenticate" do
    allow(GithubClient).to receive(:for).and_raise(ArgumentError, "user must have a github_token")

    response = call_tool

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("github_token")
  end
end
