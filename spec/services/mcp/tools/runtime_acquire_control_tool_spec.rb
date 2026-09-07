require "rails_helper"

RSpec.describe Mcp::Tools::RuntimeAcquireControlTool do
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

  it "acquires an input-mode lease as the agent" do
    session
    body = payload(call(mode: "input", reason: "click a button"))

    expect(body).to include(owner: "agent", mode: "input", reason: "click a button", state: "active", cancellable: true)
    lease = RuntimeControlLease.find(body[:id])
    expect(lease.owner_ref).to eq("coding_mode_chat:#{chat_session.id}")
  end

  it "clamps duration_seconds to the model's allowed range" do
    session
    body = payload(call(mode: "build", reason: "reload", duration_seconds: 5))

    expect(Time.iso8601(body[:expires_at])).to be_within(1.second).of(RuntimeControlLease::MIN_DURATION.from_now)
  end

  it "rejects observe_only" do
    session
    response = call(mode: "observe_only", reason: "just looking")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("mode must be one of")
  end

  it "rejects an unknown mode" do
    session
    response = call(mode: "flying", reason: "why not")

    expect(response).to be_error
  end

  it "surfaces a conflict when the serialization group is already held" do
    session
    call(mode: "input", reason: "first")

    response = call(mode: "input", reason: "second")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("already has an active")
  end

  it "allows independent build and input leases at once" do
    session
    call(mode: "input", reason: "typing")

    response = call(mode: "build", reason: "reloading")

    expect(response).not_to be_error
  end

  it "returns an error when there is no active session" do
    response = call(mode: "input", reason: "click")

    expect(response).to be_error
  end
end
