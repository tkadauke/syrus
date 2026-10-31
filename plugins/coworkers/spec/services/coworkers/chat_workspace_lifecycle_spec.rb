require "rails_helper"
require "fileutils"
require "tmpdir"

RSpec.describe Coworkers::ChatWorkspaceLifecycle do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url)
  end
  let(:scope) { Syrus::EffectScope.new(label: "coworker workspace lifecycle spec") }

  before do
    @root = Pathname(Dir.mktmpdir("coworker-workspace-spec-"))
    @remote = @root.join("remote.git")
    run_git("init", "--bare", @remote.to_s)
    seed = @root.join("seed")
    run_git("init", "--initial-branch=seed", seed.to_s)
    write(seed, ".gitattributes", "memory/** merge=union\n")
    write(seed, "SOUL.md", "role: tester\n")
    write(seed, "shared.md", "first\ntwo\nthree\nfour\nlast\n")
    write(seed, "memory/daily.md", "start\n")
    run_git("add", ".", chdir: seed)
    run_git("-c", "user.name=Maya", "-c", "user.email=maya@example.test", "commit", "-m", "seed", chdir: seed)
    run_git("push", @remote.to_s, "HEAD:refs/heads/coworkers/maya", chdir: seed)
    Coworkers::ChatExtension.install_into(scope)
    allow(ChatWorkspace).to receive(:data_root).and_return(@root.join("data"))
  end

  after do
    scope.dispose
    FileUtils.rm_rf(@root)
  end

  def chat
    session = ChatSession.create!(user: owner, repository: repository, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: session, role: Coworkers::Chat.where(coworker: coworker).exists? ? "side" : "main")
    session
  end

  def lifecycle(session)
    described_class.new(session, remote_url: @remote.to_s, repository: repository)
  end

  def run_git(*args, chdir: nil)
    options = chdir ? { chdir: chdir.to_s } : {}
    stdout, stderr, status = Open3.capture3("git", *args, **options)
    raise stderr unless status.success?
    stdout
  end

  def write(root, relative, content)
    path = root.join(relative)
    FileUtils.mkdir_p(path.dirname)
    path.write(content)
  end

  def home_file(relative)
    checkout = @root.join("inspect-#{SecureRandom.hex(4)}")
    run_git("clone", "--branch", "coworkers/maya", @remote.to_s, checkout.to_s)
    checkout.join(relative).read
  end

  it "merges disjoint and clean same-file edits from chats run in sequence" do
    first = chat
    first_lifecycle = lifecycle(first)
    first_path = first_lifecycle.prepare!
    write(first_path, "first.md", "one\n")
    first_lifecycle.finalize!

    second = chat
    second_lifecycle = lifecycle(second)
    second_path = second_lifecycle.prepare!
    write(second_path, "SOUL.md", "role: tester\nvoice: concise\n")
    second_lifecycle.finalize!

    expect(home_file("first.md")).to eq("one\n")
    expect(home_file("SOUL.md")).to include("voice: concise")
  end

  it "merges overlapping chat branches with disjoint files and union-merges concurrent memory appends" do
    first = chat
    second = chat
    first_lifecycle = lifecycle(first)
    second_lifecycle = lifecycle(second)
    first_path = first_lifecycle.prepare!
    second_path = second_lifecycle.prepare!
    write(first_path, "from-first.md", "first\n")
    write(second_path, "from-second.md", "second\n")
    write(first_path, "shared.md", "FIRST\ntwo\nthree\nfour\nlast\n")
    write(second_path, "shared.md", "first\ntwo\nthree\nfour\nLAST\n")
    write(first_path, "memory/daily.md", "start\nfirst append\n")
    write(second_path, "memory/daily.md", "start\nsecond append\n")

    first_lifecycle.finalize!
    second_lifecycle.finalize!

    expect(home_file("from-first.md")).to eq("first\n")
    expect(home_file("from-second.md")).to eq("second\n")
    expect(home_file("shared.md")).to eq("FIRST\ntwo\nthree\nfour\nLAST\n")
    expect(home_file("memory/daily.md")).to include("first append", "second append")
  end

  it "keeps a real conflict in the chat checkout and posts visible Markdown file links" do
    first = chat
    second = chat
    first_lifecycle = lifecycle(first)
    second_lifecycle = lifecycle(second)
    first_path = first_lifecycle.prepare!
    second_path = second_lifecycle.prepare!
    write(first_path, "SOUL.md", "role: first\n")
    write(second_path, "SOUL.md", "role: second\n")
    first_lifecycle.finalize!

    expect { second_lifecycle.finalize! }.to change(second.messages, :count).by(1)
    conflict = second.messages.last.content.fetch("coworker_workspace_conflict")
    visible_text = second.messages.last.content.fetch("text")
    expect(conflict.fetch("files")).to eq([ "SOUL.md" ])
    expect(conflict.fetch("links").first).to include("/chats/#{second.id}", "SOUL.md")
    expect(visible_text).to include("[SOUL.md](#{conflict.fetch('links').first})")
    expect(second.messages.last.content.fetch("body_format")).to eq("markdown")
    expect(second.messages.last.content.fetch("prominent")).to be(true)
    expect(second.messages.last.content).to include("system_label" => "Workspace conflict", "system_tone" => "warning")
    expect(second_path.join("SOUL.md").read).to include("<<<<<<<", "role: first", "role: second")
    expect(home_file("SOUL.md")).to eq("role: first\n")

    expect { second_lifecycle.finalize! }.to change(second.messages, :count).by(1)
    expect(run_git("status", "--porcelain", chdir: second_path)).to include("UU SOUL.md")
  end

  it "preserves a conflicting background run and surfaces it in the main chat" do
    session = chat
    background_path = @root.join("background")
    run_git("clone", "--branch", "coworkers/maya", @remote.to_s, background_path.to_s)
    write(background_path, "SOUL.md", "role: background\n")

    foreground = lifecycle(session)
    foreground_path = foreground.prepare!
    write(foreground_path, "SOUL.md", "role: foreground\n")
    foreground.finalize!

    outcome = lifecycle(session).finalize_background!(
      path: background_path, workflow: instance_double(Workflow, id: 47)
    )

    expect(outcome).to eq(:conflict)
    conflict = session.messages.last.content.fetch("coworker_workspace_conflict")
    expect(conflict).to include(
      "branch" => "coworkers/run/#{coworker.id}-47", "files" => [ "SOUL.md" ]
    )
    expect(conflict.fetch("ref")).to match(/\A[0-9a-f]{40}\z/)
    expect(conflict.fetch("links").first).to include("ref=#{conflict.fetch('ref')}")
    expect(background_path.join("SOUL.md").read).to include("<<<<<<<", "role: foreground", "role: background")
    preserved = run_git("show", "#{conflict.fetch('ref')}:SOUL.md", chdir: @remote)
    expect(preserved).to include("<<<<<<<", "role: foreground", "role: background")
    expect(home_file("SOUL.md")).to eq("role: foreground\n")
  end

  it "bounds each background Git operation below the shared Git timeout" do
    session = chat
    background_path = @root.join("bounded-background")
    run_git("clone", "--branch", "coworkers/maya", @remote.to_s, background_path.to_s)
    git = GitRunner.new
    allow(git).to receive(:run).and_call_original

    outcome = described_class.new(session, git:, remote_url: @remote.to_s, repository:).finalize_background!(
      path: background_path, workflow: instance_double(Workflow, id: 48)
    )

    expect(outcome).to eq(:merged)
    expect(git).to have_received(:run).with(
      "push", @remote.to_s, "HEAD:refs/heads/coworkers/run/#{coworker.id}-48",
      chdir: background_path.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" },
      timeout: described_class::BACKGROUND_GIT_TIMEOUT
    )
  end

  it "re-clones a missing local checkout from the durable chat branch" do
    session = chat
    service = lifecycle(session)
    path = service.prepare!
    write(path, "durable.md", "kept\n")
    service.finalize!
    FileUtils.rm_rf(path)

    restored = lifecycle(session).prepare!

    expect(restored.join("durable.md").read).to eq("kept\n")
    expect(run_git("branch", "--show-current", chdir: restored).strip).to eq("coworkers/chat/#{coworker.id}-#{session.id}")
    expect(run_git("log", "-1", "--format=%an <%ae>", chdir: restored).strip)
      .to eq("Maya (@maya) <maya@coworkers.syrus.invalid>")
    expect(run_git("remote", "get-url", "origin", chdir: restored).strip).to eq(repository.remote_url)
  end
end
