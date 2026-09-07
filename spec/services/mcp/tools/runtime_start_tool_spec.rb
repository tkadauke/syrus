require "rails_helper"

RSpec.describe Mcp::Tools::RuntimeStartTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }

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

  def with_workspace
    Dir.mktmpdir do |dir|
      allow(ChatWorkspace).to receive(:repo_path_for).with(chat_session, repository).and_return(Pathname.new(dir))
      yield dir
    end
  end

  it "starts a session with an explicit provider and marks it primary and running" do
    with_workspace do |dir|
      response = call(provider: "stub")
      body = payload(response)

      expect(response).not_to be_error
      expect(body).to include(provider_key: "stub", display_name: "Stub Provider", state: "running", primary: true, workspace_ref: dir)
      expect(body[:capabilities]).to eq(stream: "screenshot", input: [ "pointer" ])

      session = RuntimeSession.find(body[:id])
      expect(session.chat_session).to eq(chat_session)
      expect(session.metadata).to include("pid" => 123, "port" => 4000)
    end
  end

  it "auto-detects a provider when none is given" do
    with_workspace do
      body = payload(call)

      expect(body[:provider_key]).to eq("stub")
    end
  end

  it "uses the given name over the provider's display name" do
    with_workspace do
      body = payload(call(provider: "stub", name: "My Dev Server"))

      expect(body[:display_name]).to eq("My Dev Server")
    end
  end

  it "does not mark a second session primary while one is already active" do
    with_workspace do
      first = payload(call(provider: "stub"))
      second = payload(call(provider: "stub"))

      expect(first[:primary]).to be true
      expect(second[:primary]).to be false
    end
  end

  it "returns an error for an unknown provider" do
    with_workspace do
      response = call(provider: "nonexistent")

      expect(response).to be_error
      expect(response.content.first[:text]).to include("Unknown runtime session provider")
    end
  end

  it "returns an error when no provider can be detected and none is given" do
    Dir.mktmpdir do |dir|
      allow(ChatWorkspace).to receive(:repo_path_for).with(chat_session, repository).and_return(Pathname.new(dir))
      allow(stub_runtime_provider_class).to receive(:detect).and_return(false)

      response = call

      expect(response).to be_error
      expect(response.content.first[:text]).to include("no runtime session provider detected")
    end
  end

  it "returns an error when there is no Coding Mode checkout yet" do
    allow(ChatWorkspace).to receive(:repo_path_for).with(chat_session, repository).and_return(Pathname.new("/nonexistent/path"))

    response = call(provider: "stub")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("no Coding Mode checkout found")
  end

  it "marks the session failed when the provider raises while starting" do
    with_workspace do
      allow_any_instance_of(stub_runtime_provider_class).to receive(:start_session).and_raise("boom")

      response = call(provider: "stub")

      expect(response).to be_error
      expect(response.content.first[:text]).to include("boom")
      expect(RuntimeSession.last.state).to eq("failed")
      expect(RuntimeSession.last.last_error).to include("boom")
    end
  end

  it "returns an error when Coding Mode is disabled" do
    enable_coding_mode!(enabled: false)

    response = call(provider: "stub")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("not enabled")
  end
end
