require "rails_helper"
require "tmpdir"

RSpec.describe Mcp::Tools::AttachRepositoryTool, :ci_only do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "tkadauke", name: "syrus", default_branch: "main") }
  let(:chat_session) { ChatSession.create!(user: user) }
  let(:bare_remote_dir) { Pathname.new(Dir.mktmpdir("syrus-attach-tool-bare")) }

  before do
    seed_remote(bare_remote_dir)
    repository
    allow_any_instance_of(Repository).to receive(:remote_url).and_return("file://#{bare_remote_dir}")
    allow_any_instance_of(Repository).to receive(:authenticated_push_url).and_return("file://#{bare_remote_dir}")
    @data_root = Dir.mktmpdir("syrus-attach-tool-data")
    ENV["SYRUS_DATA_ROOT"] = @data_root
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(bare_remote_dir)
    FileUtils.rm_rf(@data_root) if @data_root
  end

  it "attaches, clones, and returns the chat workspace and repository paths" do
    response = described_class.call(slug: "tkadauke/syrus", server_context: { chat_session: chat_session })
    payload = JSON.parse(response.content.first[:text])

    workspace_path = Pathname.new(payload.fetch("workspace_path"))
    repository_path = Pathname.new(payload.fetch("repository_path"))

    expect(payload.fetch("repository")).to include("slug" => "tkadauke/syrus")
    expect(workspace_path).to eq(Pathname.new(@data_root).join("chat-workspaces", chat_session.id.to_s))
    expect(repository_path.join(".git")).to exist
    expect(chat_session.reload.attached_repositories).to contain_exactly(repository)
    expect(chat_session.workspace_path).to eq(workspace_path.to_s)
  end

  it "is idempotent and fast-forwards an existing checkout" do
    response = described_class.call(slug: "tkadauke/syrus", server_context: { chat_session: chat_session })
    repository_path = Pathname.new(JSON.parse(response.content.first[:text]).fetch("repository_path"))

    add_remote_commit("fast-forwarded")

    described_class.call(slug: "tkadauke/syrus", server_context: { chat_session: chat_session })

    expect(repository_path.join("README.md").read).to include("fast-forwarded")
    expect(chat_session.reload.repository_attachments.count).to eq(1)
  end

  it "returns a tool error for an unknown repository slug" do
    response = described_class.call(slug: "tkadauke/missing", server_context: { chat_session: chat_session })

    expect(response.instance_variable_get(:@error)).to eq(true)
    expect(response.content.first[:text]).to include("not configured")
  end

  it "returns a tool error for an archived repository slug" do
    repository.archive!

    response = described_class.call(slug: "tkadauke/syrus", server_context: { chat_session: chat_session })

    expect(response.instance_variable_get(:@error)).to eq(true)
    expect(response.content.first[:text]).to include("not configured")
    expect(chat_session.reload.attached_repositories).to be_empty
  end

  it "returns a tool error (not a -32603 crash) when no GitHub credential is available" do
    # No active App installation + a blank PAT makes GithubClient.for raise
    # ArgumentError; the tool must surface it rather than let it escape.
    repository
    user.update!(github_token: nil)

    expect {
      response = described_class.call(slug: "tkadauke/syrus", server_context: { chat_session: chat_session })

      expect(response.instance_variable_get(:@error)).to eq(true)
      expect(response.content.first[:text]).to match(/could not authenticate|GitHub token/i)
    }.not_to raise_error
  end

  def seed_remote(bare_path)
    Dir.mktmpdir("syrus-attach-tool-seed") do |seed|
      sh("git init -q -b main #{seed}")
      File.write(Pathname.new(seed).join("README.md"), "# Syrus\n")
      sh("git -C #{seed} add README.md")
      sh("git -C #{seed} commit -q -m 'initial' --author='Seed <s@e>'")
      FileUtils.mkdir_p(bare_path.dirname)
      sh("git clone -q --bare #{seed} #{bare_path}")
    end
  end

  def add_remote_commit(text)
    Dir.mktmpdir("syrus-attach-tool-update") do |seed|
      sh("git clone -q #{bare_remote_dir} #{seed}")
      File.open(Pathname.new(seed).join("README.md"), "a") { |f| f.puts text }
      sh("git -C #{seed} add README.md")
      sh("git -C #{seed} commit -q -m 'update' --author='Seed <s@e>'")
      sh("git -C #{seed} push -q origin main")
    end
  end

  def sh(cmd)
    out, err, status = Open3.capture3(
      { "GIT_AUTHOR_NAME" => "Seed", "GIT_AUTHOR_EMAIL" => "s@e",
        "GIT_COMMITTER_NAME" => "Seed", "GIT_COMMITTER_EMAIL" => "s@e" },
      cmd
    )
    raise "shell failed: #{cmd}\n#{out}\n#{err}" unless status.success?
    out
  end
end
