require "rails_helper"
require "open3"
require "tmpdir"

RSpec.describe CodingHandoffCapture, :ci_only do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "tkadauke", name: "syrus", default_branch: "main") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def git!(path, *args)
    out, err, status = Open3.capture3("git", *args, chdir: path.to_s)
    raise "git #{args.join(' ')} failed:\n#{out}\n#{err}" unless status.success?

    out
  end

  def write_file(path, relative, contents)
    target = Pathname.new(path).join(relative)
    FileUtils.mkdir_p(target.dirname)
    File.write(target, contents)
  end

  around do |example|
    Dir.mktmpdir("syrus-coding-handoff-capture") do |dir|
      @root = Pathname.new(dir)
      @remote = @root.join("origin.git")
      @checkout = @root.join("checkout")

      git!(@root, "init", "--bare", @remote.to_s)
      seed = @root.join("seed")
      git!(@root, "init", seed.to_s)
      git!(seed, "config", "user.name", "Test User")
      git!(seed, "config", "user.email", "test@example.com")
      write_file(seed, "README.md", "hello\n")
      git!(seed, "add", "README.md")
      git!(seed, "commit", "-m", "Initial")
      git!(seed, "branch", "-M", "main")
      git!(seed, "remote", "add", "origin", @remote.to_s)
      git!(seed, "push", "origin", "main")
      git!(@remote, "symbolic-ref", "HEAD", "refs/heads/main")

      git!(@root, "clone", @remote.to_s, @checkout.to_s)
      git!(@checkout, "config", "user.name", "Chat Agent")
      git!(@checkout, "config", "user.email", "chat@example.com")

      example.run
    end
  end

  before do
    allow(ChatWorkspace).to receive(:repo_path_for).with(chat_session, repository).and_return(@checkout)
    allow(repository).to receive(:authenticated_push_url).and_return(@remote.to_s)
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(instance_double(GithubClient, access_token: "token"))
  end

  it "publishes the exact current chat commit to an immutable handoff branch" do
    write_file(@checkout, "app/models/widget.rb", "class Widget\nend\n")
    git!(@checkout, "add", "app/models/widget.rb")
    git!(@checkout, "commit", "-m", "Add widget")
    head_sha = git!(@checkout, "rev-parse", "HEAD").strip

    snapshot = described_class.capture!(
      chat_session: chat_session,
      repository: repository,
      user: user,
      source_branch: "main",
      handoff_branch: "syrus/chat-#{chat_session.id}-handoff-123"
    )

    remote_sha = git!(@remote, "rev-parse", "refs/heads/syrus/chat-#{chat_session.id}-handoff-123").strip
    expect(remote_sha).to eq(head_sha)
    expect(snapshot).to include(
      "source_branch" => "main",
      "handoff_branch" => "syrus/chat-#{chat_session.id}-handoff-123",
      "head_sha" => head_sha,
      "default_branch" => "main",
      "changed_files" => [ "app/models/widget.rb" ],
      "chat_session_id" => chat_session.id
    )
  end

  it "refuses to capture a branch with no committed changes against the default branch" do
    expect {
      described_class.capture!(
        chat_session: chat_session,
        repository: repository,
        user: user,
        source_branch: "main",
        handoff_branch: "syrus/chat-#{chat_session.id}-handoff-123"
      )
    }.to raise_error(described_class::CaptureError, /no committed changes/)
  end

  it "refuses to capture from a different active branch" do
    write_file(@checkout, "app/models/widget.rb", "class Widget\nend\n")
    git!(@checkout, "add", "app/models/widget.rb")
    git!(@checkout, "commit", "-m", "Add widget")

    expect {
      described_class.capture!(
        chat_session: chat_session,
        repository: repository,
        user: user,
        source_branch: "different-branch",
        handoff_branch: "syrus/chat-#{chat_session.id}-handoff-123"
      )
    }.to raise_error(described_class::CaptureError, /expected "different-branch"/)
  end
end
