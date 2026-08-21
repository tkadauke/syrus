require "rails_helper"
require "rack/mock"
require "tmpdir"

RSpec.describe PersistentMcpDaemon::InvocationContextTool do
  let(:data_root) { Dir.mktmpdir("syrus-persistent-mcp-daemon-invocation-context") }
  let(:daemon) { PersistentMcpDaemon.new }
  let(:worker_id) { WorkerStorageIdentity.key(data_root: data_root) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  before { ENV["SYRUS_DATA_ROOT"] = data_root }

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(data_root)
  end

  def call_tool(token, via_header: false)
    body = {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: {
        name: "daemon_invocation_context",
        arguments: {},
        _meta: (token.nil? || via_header) ? {} : { PersistentMcpDaemon::INVOCATION_CONTEXT_META_KEY => token }
      }
    }.to_json

    headers = {
      "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json, text/event-stream"
    }
    headers[PersistentMcpDaemon::INVOCATION_CONTEXT_HEADER_ENV_KEY] = token if via_header && token

    env = Rack::MockRequest.env_for("/mcp", method: "POST", input: body, **headers)
    response = daemon.call(env)
    JSON.parse(response[2].first).dig("result")
  end

  def tool_payload(result)
    JSON.parse(result.dig("content", 0, "text"))
  end

  it "reconstructs the run's McpToolContext over the real MCP dispatch path" do
    run = Factories.job(repository: repository).initial_run
    token = McpInvocationContext.issue_for_run(run, worker_id: worker_id, provider: "claude")

    result = call_tool(token)
    payload = tool_payload(result)

    expect(result["isError"]).to be_falsey
    expect(payload).to include(
      "ok" => true,
      "surface" => "run",
      "run_id" => run.id,
      "job_id" => run.job_id,
      "provider" => "claude"
    )
  end

  it "reconstructs the chat session's McpToolContext over the real MCP dispatch path" do
    chat_session = ChatSession.create!(user: user, repository: repository)
    token = McpInvocationContext.issue_for_chat(chat_session, worker_id: worker_id, tier: "deferred", provider: "codex")

    result = call_tool(token)
    payload = tool_payload(result)

    expect(result["isError"]).to be_falsey
    expect(payload).to include(
      "ok" => true,
      "surface" => "chat",
      "chat_session_id" => chat_session.id,
      "tier" => "deferred",
      "provider" => "codex"
    )
  end

  it "does not leak one run's context into a dispatch carrying a different run's token" do
    run_a = Factories.job(repository: repository).initial_run
    run_b = Factories.job(repository: repository).initial_run
    token_a = McpInvocationContext.issue_for_run(run_a, worker_id: worker_id)
    token_b = McpInvocationContext.issue_for_run(run_b, worker_id: worker_id)

    payload_b = tool_payload(call_tool(token_b))
    payload_a = tool_payload(call_tool(token_a))

    expect(payload_a["run_id"]).to eq(run_a.id)
    expect(payload_b["run_id"]).to eq(run_b.id)
  end

  it "rejects and reports a missing invocation token as an error tool response" do
    result = call_tool(nil)

    expect(result["isError"]).to be true
    payload = tool_payload(result)
    expect(payload).to include("ok" => false, "error" => "Malformed")
  end

  it "rejects and reports a token minted for a different worker as an error tool response" do
    run = Factories.job(repository: repository).initial_run
    token = McpInvocationContext.issue_for_run(run, worker_id: "some-other-worker")

    result = call_tool(token)

    expect(result["isError"]).to be true
    payload = tool_payload(result)
    expect(payload).to include("ok" => false, "error" => "WrongWorker")
  end

  it "resolves the invocation context when it arrives via the header instead of _meta (claude/codex CLIs cannot set _meta directly)" do
    run = Factories.job(repository: repository).initial_run
    token = McpInvocationContext.issue_for_run(run, worker_id: worker_id, provider: "claude")

    result = call_tool(token, via_header: true)
    payload = tool_payload(result)

    expect(result["isError"]).to be_falsey
    expect(payload).to include("ok" => true, "surface" => "run", "run_id" => run.id)
  end
end
