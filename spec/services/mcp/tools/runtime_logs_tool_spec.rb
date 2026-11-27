require "rails_helper"

RSpec.describe Mcp::Tools::RuntimeLogsTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }
  let(:session) do
    RuntimeSession.create!(repository: repository, chat_session: chat_session, workspace_ref: "a", provider_key: "stub", display_name: "Stub", state: "running", primary: true)
  end

  before do
    enable_coding_mode!
    register_stub_runtime_provider!
  end

  after { Syrus::PluginRegistry.reset! }

  def call(server_context: { chat_session: chat_session }, **arguments)
    described_class.call(server_context: server_context, **arguments)
  end

  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  it "defaults cursor to the beginning" do
    session
    expect(payload(call)).to eq(entries: [ "line-0" ], cursor: 1, operation_entries: [])
  end

  it "passes the given cursor through to the provider" do
    session
    expect(payload(call(cursor: "3"))).to eq(entries: [ "line-3" ], cursor: 4, operation_entries: [])
  end

  it "returns durable operation logs alongside provider logs" do
    session.update!(metadata: {
      "runtime_operation_logs" => [ { "at" => "2026-11-27T00:00:00Z", "operation_id" => "op-1", "message" => "startup provider operation timed out" } ]
    })

    expect(payload(call)[:operation_entries]).to contain_exactly(
      at: "2026-11-27T00:00:00Z", operation_id: "op-1", message: "startup provider operation timed out"
    )
  end

  it "still returns operation evidence when provider log retrieval fails" do
    session.update!(metadata: {
      "runtime_operation_logs" => [ { "at" => "2026-11-27T00:00:00Z", "operation_id" => "op-1", "message" => "startup provider operation failed: boom" } ]
    })
    allow_any_instance_of(stub_runtime_provider_class).to receive(:logs).and_raise("log transport unavailable")

    body = payload(call)

    expect(body[:provider_error]).to include("log transport unavailable")
    expect(body[:operation_entries].first[:message]).to include("provider operation failed")
  end
end
