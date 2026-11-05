require "rails_helper"
require "fileutils"
require "tmpdir"

RSpec.describe Coworkers::ChatWorkspaceLifecycle, :allow_host_execution do
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

  it "persists a preference written through the advertised coworker tool to the home branch" do
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    coworker.grants.create!(capability: "workspace.files", approval_policy: "auto")
    session = chat
    service = lifecycle(session)
    service.prepare!

    tools = Mcp::Sidecar.send(:plugin_tools_for, session, tier: :essential, policy: :coworker)
    tool = tools.find do |candidate|
      McpToolRegistry.tool_name_for(candidate) == "write_coworker_file"
    end
    expect(tool).to be_present
    expect(tool.call(path: "preferences.md", content: "Reviews: exhaustive\n",
      server_context: { chat_session: session })).not_to be_error

    service.finalize!

    expect(home_file("preferences.md")).to eq("Reviews: exhaustive\n")
    expect(run_git("log", "-1", "--format=%s", "coworkers/maya", chdir: @remote).strip)
      .to eq("Update @maya from chat #{session.id}")
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

  it "silently lets the coworker resolve a real conflict on the next turn" do
    first = chat
    second = chat
    first_lifecycle = lifecycle(first)
    second_lifecycle = lifecycle(second)
    first_path = first_lifecycle.prepare!
    second_path = second_lifecycle.prepare!
    write(first_path, "SOUL.md", "role: first\n")
    write(second_path, "SOUL.md", "role: second\n")
    first_lifecycle.finalize!

    expect { second_lifecycle.finalize! }.not_to change(second.messages, :count)
    conflict = Coworkers::WorkspaceConflict.active.find_by!(chat_session: second)
    expect(conflict.files).to eq([ "SOUL.md" ])
    expect(second_path.join("SOUL.md").read).to include("<<<<<<<", "role: first", "role: second")
    expect(home_file("SOUL.md")).to eq("role: first\n")

    concurrent = lifecycle(chat)
    concurrent_path = concurrent.prepare!
    write(concurrent_path, "concurrent.md", "home moved\n")
    concurrent.finalize!

    write(second_path, "SOUL.md", "role: first and second\n")
    expect { second_lifecycle.finalize! }.not_to change(second.messages, :count)
    expect(conflict.reload.state).to eq("resolved")
    expect(run_git("status", "--porcelain", chdir: second_path)).to be_blank
    expect(home_file("SOUL.md")).to eq("role: first and second\n")
    expect(home_file("concurrent.md")).to eq("home moved\n")
  end

  it "warns once after bounded conflict validation failures" do
    first = chat
    second = chat
    first_service = lifecycle(first)
    second_service = lifecycle(second)
    write(first_service.prepare!, "SOUL.md", "role: first\n")
    second_path = second_service.prepare!
    write(second_path, "SOUL.md", "role: second\n")
    first_service.finalize!
    second_service.finalize!

    expect { second_service.finalize! }.not_to change(second.messages, :count)
    write(second_path, "SOUL.md", second_path.join("SOUL.md").read.sub("role: second", "role: second draft"))
    expect { second_service.finalize! }.not_to change(second.messages, :count)
    write(second_path, "SOUL.md", second_path.join("SOUL.md").read.sub("role: second draft", "role: second revision"))
    expect { second_service.finalize! }.to change(second.messages, :count).by(1)
    expect { second_service.finalize! }.not_to change(second.messages, :count)
    expect(second.messages.last.content.fetch("coworker_workspace_conflict").fetch("files")).to eq([ "SOUL.md" ])

    write(second_path, "SOUL.md", "role: first and second\n")
    expect { second_service.finalize! }.not_to change(second.messages, :count)
    expect(Coworkers::WorkspaceConflict.find_by!(chat_session: second).state).to eq("resolved")
  end

  it "does not spend a retry when a later turn leaves the conflicted files untouched" do
    first = chat
    second = chat
    first_service = lifecycle(first)
    second_service = lifecycle(second)
    write(first_service.prepare!, "SOUL.md", "role: first\n")
    second_path = second_service.prepare!
    write(second_path, "SOUL.md", "role: second\n")
    first_service.finalize!
    second_service.finalize!

    3.times { expect(second_service.finalize!).to eq(:pending_resolution) }

    expect(Coworkers::WorkspaceConflict.active.find_by!(chat_session: second).attempt_count).to eq(0)
    expect(second.messages).to be_empty
  end

  it "does not follow an unmerged symlink outside the workspace" do
    session = chat
    service = lifecycle(session)
    path = service.prepare!
    outside = @root.join("worker-secret")
    outside.write("host credential material")
    link = path.join("SOUL.md")
    link.delete
    File.symlink(outside, link)
    blob = run_git("rev-parse", "HEAD:SOUL.md", chdir: path).strip
    index_info = "120000 #{blob} 2\tSOUL.md\n120000 #{blob} 3\tSOUL.md\n"
    _stdout, stderr, status = Open3.capture3("git", "update-index", "--index-info", chdir: path.to_s,
      stdin_data: index_info)
    raise stderr unless status.success?

    expect(service.send(:unmerged_files, path)).to eq([ "SOUL.md" ])
    versions = service.send(:conflict_versions, path, [ "SOUL.md" ])
    markers = service.send(:conflict_markers, path, [ "SOUL.md" ])

    expect(versions.fetch("SOUL.md")).to include("source unavailable")
    expect(versions.fetch("SOUL.md")).not_to include("host credential material")
    expect(markers).to eq([ "SOUL.md" ])
  end

  it "does not reuse a notified failed record for an unrelated conflict" do
    session = chat
    branch = "coworkers/chat/#{coworker.id}-#{session.id}"
    Coworkers::WorkspaceConflict.create!(chat_session: session, repository:, source_branch: branch,
      files: [ "SOUL.md" ], versions: { "SOUL.md" => "old conflict" }, state: "failed",
      notified_at: Time.current, expires_at: 1.minute.ago)

    match = lifecycle(session).send(:terminal_conflict, files: [ "USER.md" ], source_branch: branch)

    expect(match).to be_nil
  end

  it "keeps a diff-check validation failure private and accepts a corrected retry" do
    first = chat
    second = chat
    first_service = lifecycle(first)
    second_service = lifecycle(second)
    write(first_service.prepare!, "SOUL.md", "role: first\n")
    second_path = second_service.prepare!
    write(second_path, "SOUL.md", "role: second\n")
    first_service.finalize!
    second_service.finalize!

    write(second_path, "SOUL.md", "role: combined \n")
    expect { second_service.finalize! }.not_to change(second.messages, :count)
    conflict = Coworkers::WorkspaceConflict.active.find_by!(chat_session: second)
    conflict.reload
    expect(conflict).to have_attributes(attempt_count: 1)
    expect(conflict.detail).to include("trailing whitespace")

    write(second_path, "SOUL.md", "role: combined\n")
    expect(second_service.finalize!).to eq(:merged)
    expect(conflict.reload.state).to eq("resolved")
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

    outcome = nil
    expect do
      outcome = lifecycle(session).finalize_background!(
        path: background_path, workflow: instance_double(Workflow, id: 47)
      )
    end.to have_enqueued_job(Coworkers::WorkspaceConflictTimeoutJob)

    expect(outcome).to eq(:pending_resolution)
    expect(session.messages).to be_empty
    conflict = Coworkers::WorkspaceConflict.active.find_by!(chat_session: session)
    expect(conflict).to have_attributes(source_branch: "coworkers/run/#{coworker.id}-47", files: [ "SOUL.md" ])
    expect(conflict.recovery_ref).to match(/\A[0-9a-f]{40}\z/)
    expect(background_path.join("SOUL.md").read).to include("<<<<<<<", "role: foreground", "role: background")
    preserved = run_git("show", "#{conflict.recovery_ref}:SOUL.md", chdir: @remote)
    expect(preserved).to include("<<<<<<<", "role: foreground", "role: background")
    expect(home_file("SOUL.md")).to eq("role: foreground\n")
  end

  it "warns once when the silent resolution deadline expires" do
    session = chat
    conflict = Coworkers::WorkspaceConflict.create!(chat_session: session, repository:,
      source_branch: "coworkers/run/#{coworker.id}-99", recovery_ref: "a" * 40,
      files: [ "SOUL.md" ], versions: { "SOUL.md" => "both sides" },
      expires_at: 1.minute.ago)

    2.times { Coworkers::WorkspaceConflictTimeoutJob.perform_now(conflict.id) }

    expect(conflict.reload).to have_attributes(state: "failed")
    expect(session.messages.count).to eq(1)
    expect(session.messages.last.content.fetch("coworker_workspace_conflict")).to include(
      "ref" => "a" * 40, "files" => [ "SOUL.md" ]
    )
  end

  it "commits every uncommitted background change with the coworker identity before merging" do
    session = chat
    background_path = @root.join("uncommitted-background")
    run_git("clone", "--branch", "coworkers/maya", @remote.to_s, background_path.to_s)
    write(background_path, "memory/new.md", "new memory\n")
    write(background_path, "SOUL.md", "role: meticulous tester\n")
    FileUtils.mv(background_path.join("shared.md"), background_path.join("renamed.md"))
    FileUtils.rm(background_path.join("memory/daily.md"))

    outcome = lifecycle(session).finalize_background!(
      path: background_path, workflow: instance_double(Workflow, id: 49)
    )

    expect(outcome).to eq(:merged)
    expect(home_file("memory/new.md")).to eq("new memory\n")
    expect(home_file("SOUL.md")).to eq("role: meticulous tester\n")
    expect(home_file("renamed.md")).to eq("first\ntwo\nthree\nfour\nlast\n")
    expect { home_file("shared.md") }.to raise_error(Errno::ENOENT)
    expect { home_file("memory/daily.md") }.to raise_error(Errno::ENOENT)
    expect(run_git("log", "-1", "--format=%an <%ae>", "coworkers/maya", chdir: @remote).strip)
      .to eq("Maya (@maya) <maya@coworkers.syrus.invalid>")
  end

  it "merges an agent-authored background commit without requiring more workspace edits" do
    session = chat
    background_path = @root.join("committed-background")
    run_git("clone", "--branch", "coworkers/maya", @remote.to_s, background_path.to_s)
    write(background_path, "memory/committed.md", "legacy agent commit\n")
    run_git("add", "--all", chdir: background_path)
    run_git("-c", "user.name=Agent", "-c", "user.email=agent@example.test", "commit", "-m", "legacy commit", chdir: background_path)

    outcome = lifecycle(session).finalize_background!(
      path: background_path, workflow: instance_double(Workflow, id: 50)
    )

    expect(outcome).to eq(:merged)
    expect(home_file("memory/committed.md")).to eq("legacy agent commit\n")
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

  it "preserves unsaved local work across a following turn and clears state after recovery" do
    session = chat
    service = lifecycle(session)
    path = service.prepare!
    write(path, "preserved.md", "do not lose this\n")
    unavailable_remote = @root.join("remote-unavailable.git")
    FileUtils.mv(@remote, unavailable_remote)
    expect(service.finalize!).to eq(:unsaved)
    expect(session.coworker_chat.reload).to be_unsaved_workspace
    expect(path.join("preserved.md").read).to eq("do not lose this\n")
    FileUtils.mv(unavailable_remote, @remote)
    following_turn = lifecycle(session)
    expect(following_turn.prepare!).to eq(path)
    expect(following_turn.finalize!).to eq(:merged)
    expect(session.coworker_chat.reload).not_to be_unsaved_workspace
    expect(home_file("preserved.md")).to eq("do not lose this\n")
  ensure
    FileUtils.mv(unavailable_remote, @remote) if unavailable_remote&.exist? && !@remote.exist?
  end
end
