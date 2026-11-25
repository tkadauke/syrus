require "rails_helper"

RSpec.describe Mcp::Tools::RuntimeStartTool, full_chat_access: :all do
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

  it "starts against an explicitly selected attached repository and persists its runtime workspace" do
    product_repository = Factories.repository(user: user, owner: "acme", name: "product")
    chat_session.chat_attachments.create!(attachable: product_repository)

    Dir.mktmpdir do |runtime_workspace|
      allow(ChatWorkspace).to receive(:runtime_workspace_for!)
        .with(chat_session, product_repository).and_return(Pathname.new(runtime_workspace))
      expect_any_instance_of(stub_runtime_provider_class).to receive(:start_session)
        .with(runtime_workspace, hash_including(chat_session: chat_session, workspace_path: runtime_workspace))
        .and_call_original

      body = payload(call(provider: "stub", repository_slug: product_repository.slug))
      session = RuntimeSession.find(body[:id])

      expect(session.repository).to eq(product_repository)
      expect(session.workspace_ref).to eq(runtime_workspace)
    end
  end

  it "defaults to the sole attached repository" do
    with_workspace do
      body = payload(call(provider: "stub"))

      expect(RuntimeSession.find(body[:id]).repository).to eq(repository)
    end
  end

  it "requires a repository target when multiple repositories are attached" do
    other_repository = Factories.repository(user: user, owner: "acme", name: "other")
    chat_session.chat_attachments.create!(attachable: other_repository)

    response = call(provider: "stub")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("multiple repositories are attached")
    expect(response.content.first[:text]).to include(repository.slug, other_repository.slug)
    expect(RuntimeSession.count).to eq(0)
  end

  it "accepts an attached repository id" do
    other_repository = Factories.repository(user: user, owner: "acme", name: "other")
    chat_session.chat_attachments.create!(attachable: other_repository)

    Dir.mktmpdir do |runtime_workspace|
      allow(ChatWorkspace).to receive(:runtime_workspace_for!)
        .with(chat_session, other_repository).and_return(Pathname.new(runtime_workspace))

      body = payload(call(provider: "stub", repository_id: other_repository.id))

      expect(RuntimeSession.find(body[:id]).repository).to eq(other_repository)
    end
  end

  it "rejects an accessible repository that is not attached" do
    unattached_repository = Factories.repository(user: user, owner: "acme", name: "unattached")

    response = call(provider: "stub", repository_id: unattached_repository.id)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("not attached")
  end

  it "rejects an attached repository that is inaccessible to the current user" do
    foreign_repository = Factories.repository(user: Factories.user, owner: "private", name: "foreign")
    chat_session.chat_attachments.create!(attachable: foreign_repository)

    response = call(provider: "stub", repository_id: foreign_repository.id)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("not attached", "not accessible")
  end

  it "rejects filesystem paths as repository slugs" do
    response = call(provider: "stub", repository_slug: "/tmp/product")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("owner/name form")
  end

  it "rejects conflicting repository selectors" do
    response = call(provider: "stub", repository_id: repository.id, repository_slug: repository.slug)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("either `repository_id` or `repository_slug`")
  end

  it "uses the given name over the provider's display name" do
    with_workspace do
      body = payload(call(provider: "stub", name: "My Dev Server"))

      expect(body[:display_name]).to eq("My Dev Server")
    end
  end

  it "lets two attached repositories host separate sessions without changing the primary" do
    other_repository = Factories.repository(user: user, owner: "acme", name: "other")
    chat_session.chat_attachments.create!(attachable: other_repository)

    Dir.mktmpdir do |workspace|
      allow(ChatWorkspace).to receive(:runtime_workspace_for!).and_return(Pathname.new(workspace))
      first = payload(call(provider: "stub", repository_id: repository.id))
      second = payload(call(provider: "stub", repository_id: other_repository.id))

      expect(first[:primary]).to be true
      expect(second[:primary]).to be false
      expect(RuntimeSession.find(first[:id]).repository).to eq(repository)
      expect(RuntimeSession.find(second[:id]).repository).to eq(other_repository)
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

  it "returns an error when the chat has no repository workspace yet" do
    allow(ChatWorkspace).to receive(:repo_path_for).with(chat_session, repository).and_return(Pathname.new("/nonexistent/path"))

    response = call(provider: "stub")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("no repository workspace for this chat yet")
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
