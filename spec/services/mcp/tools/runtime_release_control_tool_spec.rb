require "rails_helper"

RSpec.describe Mcp::Tools::RuntimeReleaseControlTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }
  let(:session) do
    RuntimeSession.create!(repository: repository, chat_session: chat_session, workspace_ref: "a", provider_key: "browser", display_name: "Browser", state: "running", primary: true)
  end

  before { enable_coding_mode! }

  def call(server_context: { chat_session: chat_session }, **arguments)
    described_class.call(server_context: server_context, **arguments)
  end

  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  it "releases the agent's active leases" do
    input_lease = RuntimeControlLease.acquire!(runtime_session: session, owner: "agent", mode: "input", reason: "typing")
    build_lease = RuntimeControlLease.acquire!(runtime_session: session, owner: "agent", mode: "build", reason: "reloading")

    body = payload(call)

    expect(body[:released].map { |l| l[:id] }).to contain_exactly(input_lease.id, build_lease.id)
    expect(input_lease.reload.state).to eq("released")
    expect(build_lease.reload.state).to eq("released")
  end

  it "does not release a lease held by the user" do
    user_lease = RuntimeControlLease.acquire!(runtime_session: session, owner: "user", mode: "input", reason: "typing")

    body = payload(call)

    expect(body[:released]).to eq([])
    expect(user_lease.reload.state).to eq("active")
  end

  it "is a no-op when the agent holds no active lease" do
    session
    expect(payload(call)).to eq(released: [])
  end
end
