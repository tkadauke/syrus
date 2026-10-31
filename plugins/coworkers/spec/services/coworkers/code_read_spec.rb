require "rails_helper"

RSpec.describe "Coworker repository code access" do
  let(:owner) { Factories.user }
  let(:workspace_repository) { Factories.repository(user: owner) }
  let(:repository) { Factories.repository(user: owner) }
  let(:outside_repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-code",
      workspace_repo: workspace_repository.remote_url)
  end
  let(:chat) { ChatSession.create!(user: owner, repository: workspace_repository, title: "Maya") }
  let(:effect_scope) { Syrus::EffectScope.new(label: "coworker code read spec") }

  before do
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main")
    Coworkers::ChatExtension.install_into(effect_scope)
    message = chat.messages.create!(role: "user", content: { "text" => "Inspect the code" })
    chat.update_columns(current_turn_message_id: message.id, turn_in_flight: true)
    coworker.grants.create!(capability: "code.read", approval_policy: "auto", scope: [ repository.id ])
    stub_repository_content(repository, files: {
      "app/models/widget.rb" => "class Widget\n  API_TOKEN=super-secret-value\nend\n",
      "README.md" => "Widgets are useful\n"
    })
  end

  after { effect_scope.dispose }

  def payload(response) = JSON.parse(response.content.first.fetch(:text))

  it "advertises repository tools only while the grant is held, including background read parity" do
    chat_names = McpToolPolicy.for(McpToolContext.from_chat_session(chat)).map { |tool| McpToolRegistry.tool_name_for(tool) }
    expect(chat_names).to include("attach_repository", "detach_repository", "list_repository_files", "read_repository_file", "search_repository_code", "read_pr", "get_job_diff")

    run_context = McpToolContext.new(surface: :run, role: AgentRole::COWORKER, user: owner,
      repository: workspace_repository, granted_capabilities: [ "code.read" ],
      capability_scopes: { "code.read" => [ repository.id ] }, interactive: false)
    run_names = McpToolPolicy.for(run_context).map { |tool| McpToolRegistry.tool_name_for(tool) }
    expect(run_names).to include("list_repository_files", "read_repository_file", "search_repository_code", "read_pr", "get_job_diff")
    expect(run_names).not_to include("attach_repository", "detach_repository")
    expect(run_context.capability_scopes["code.read"]).to eq([ repository.id ])

    coworker.grants.delete_all
    expect(McpToolPolicy.for(McpToolContext.from_chat_session(chat)).map { |tool| McpToolRegistry.tool_name_for(tool) })
      .not_to include("attach_repository", "read_repository_file")
  end

  it "reads, redacts, searches, and refuses repositories outside the grant scope" do
    listed = payload(Mcp::Tools::ListRepositoryFilesTool.call(repository_id: repository.id, server_context: { chat_session: chat }))
    expect(listed.fetch("entries").pluck("path")).to include("app/models/widget.rb")

    read = payload(Mcp::Tools::ReadRepositoryFileTool.call(repository_id: repository.id, path: "app/models/widget.rb", server_context: { chat_session: chat }))
    expect(read.fetch("content")).to include("class Widget", "[redacted]")
    expect(read.fetch("content")).not_to include("super-secret-value")

    searched = payload(Mcp::Tools::SearchRepositoryCodeTool.call(repository_id: repository.id, query: "Widget", server_context: { chat_session: chat }))
    expect(searched.fetch("results")).to include(include("path" => "app/models/widget.rb", "line" => 1))

    refused = Mcp::Tools::ReadRepositoryFileTool.call(repository_id: outside_repository.id, path: "README.md", server_context: { chat_session: chat })
    expect(refused).to be_error
  end

  it "makes an attached product checkout non-writable while leaving unrelated workspace files writable" do
    root = Pathname(Dir.mktmpdir)
    product_path = root.join("product")
    workspace_path = root.join("workspace")
    FileUtils.mkdir_p(product_path.join(".git"))
    FileUtils.mkdir_p(workspace_path)
    product_path.join("source.rb").write("source")
    workspace_path.join("SOUL.md").write("identity")
    allow(ChatWorkspace).to receive(:repo_path_for).with(chat, repository).and_return(product_path)
    allow(ChatWorkspace).to receive(:path_for).with(chat).and_return(root)
    allow_any_instance_of(ChatWorkspace).to receive(:ensure_root!)
    allow_any_instance_of(ChatWorkspace).to receive(:fast_forward!)
    allow_any_instance_of(ChatWorkspace).to receive(:write_relay_credentials!)
    allow(ChatWorkspace).to receive(:protect_path_read_only!).and_call_original

    expect(McpToolContext.from_chat_session(chat).role).to eq(AgentRole::COWORKER_CHAT)
    expect(repository.id).not_to eq(chat.repository_id)

    response = Mcp::Tools::AttachRepositoryTool.call(slug: repository.slug, server_context: { chat_session: chat })

    expect(response).not_to be_error
    expect(ChatWorkspace).to have_received(:protect_path_read_only!).with(product_path)
    expect(product_path.join("source.rb").stat.mode & 0o222).to eq(0)
    expect(product_path.join(".git").stat.mode & 0o222).to eq(0)
    expect(workspace_path.join("SOUL.md").stat.mode & 0o200).not_to eq(0)
    File.chmod(0o755, root)
    writer = fork do
      Process::UID.change_privilege(65_534) if Process.uid.zero?
      File.open(product_path.join("source.rb"), "a") { |file| file.write("changed") }
      exit! 1
    rescue Errno::EACCES
      exit! 0
    end
    _, status = Process.wait2(writer)
    expect(status).to be_success
    expect(product_path.join("source.rb").read).to eq("source")
  ensure
    FileUtils.chmod_R(0o700, root) if root&.exist?
    FileUtils.rm_rf(root) if root
  end
end
