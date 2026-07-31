require "rails_helper"
require "tmpdir"
require "shellwords"

RSpec.describe ChatWorkspace, :ci_only do
  let(:bare_remote_dir) { Pathname.new(Dir.mktmpdir("syrus-chatws-bare")) }
  let(:user) { Factories.user(name: "Ada Lovelace", github_token: "ghp_test_token") }
  let(:repository) do
    Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main")
  end
  let(:chat_session) { ChatSession.create!(user: user) }

  before do
    seed_remote(bare_remote_dir)
    allow_any_instance_of(Repository).to receive(:remote_url).and_return("file://#{bare_remote_dir}")
    allow_any_instance_of(Repository).to receive(:authenticated_push_url).and_return("file://#{bare_remote_dir}")
    @data_root = Dir.mktmpdir("syrus-chatws-data")
    ENV["SYRUS_DATA_ROOT"] = @data_root
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(bare_remote_dir)
    FileUtils.rm_rf(@data_root) if @data_root
  end

  describe ".path_for" do
    it "is keyed on chat session id under chat-workspaces/" do
      expect(described_class.path_for(chat_session))
        .to eq(Pathname.new(@data_root).join("chat-workspaces", chat_session.id.to_s))
    end

    it "uses the persisted workspace path once provisioned" do
      path = described_class.ensure_root!(chat_session)

      expect(chat_session.reload.workspace_path).to eq(path.to_s)
      expect(described_class.path_for(chat_session)).to eq(path)
    end
  end

  describe ".agent_home_for" do
    it "is keyed on chat id and provider, outside the chat workspace" do
      expect(described_class.agent_home_for(chat_session, "codex"))
        .to eq(Pathname.new(@data_root).join("agent_homes", "chats", chat_session.id.to_s, "codex"))
    end
  end

  describe ".attach_repository!" do
    it "shallow-clones the repository on first use" do
      path = described_class.attach_repository!(chat_session, repository)

      expect(path).to exist
      expect(path.join(".git")).to exist
      expect(path).to eq(described_class.path_for(chat_session).join("repositories", "acme", "widgets"))
      expect(`git -C #{path} rev-parse --abbrev-ref HEAD`.strip).to eq("main")
      expect(chat_session.reload.attached_repositories).to contain_exactly(repository)
    end

    it "writes .syrus/ into the git info exclude file" do
      path = described_class.attach_repository!(chat_session, repository)

      exclude_entries = path.join(".git", "info", "exclude").read.lines.map(&:chomp)
      expect(exclude_entries).to include(".syrus/")
    end

    it "fetches and fast-forwards when the repository already exists" do
      path = described_class.attach_repository!(chat_session, repository)
      add_remote_commit("second")

      described_class.attach_repository!(chat_session, repository)

      expect(path.join("README.md").read).to include("second")
      expect(chat_session.reload.repository_attachments.count).to eq(1)
    end

    it "fetches existing checkouts from an authenticated URL" do
      path = described_class.repo_path_for(chat_session, repository)
      FileUtils.mkdir_p(path.join(".git", "info"))
      allow(repository).to receive(:authenticated_push_url)
        .with("ghp_test_token")
        .and_return("https://token@example.com/acme/widgets.git")
      git = ChatWorkspaceRecordingGitRunner.new

      described_class.new(chat_session, git: git).attach_repository!(repository)

      fetch = git.commands.find { |command| command[:args].first == "fetch" }
      expect(fetch[:args]).to eq(
        [
          "fetch",
          "https://token@example.com/acme/widgets.git",
          "+refs/heads/main:refs/remotes/origin/main",
          "--prune"
        ]
      )
      expect(fetch[:args]).not_to include("origin")
    end
  end

  describe ".ensure_coding_checkout!" do
    it "full-clones the repository on the default branch on first call" do
      described_class.ensure_coding_checkout!(chat_session, repository)

      path = described_class.repo_path_for(chat_session, repository)
      expect(path.join(".git")).to exist
      branch = `git -C #{path} rev-parse --abbrev-ref HEAD`.strip
      expect(branch).to eq("main")
      expect(chat_session.reload.coding_checkout_branch).to eq("main")
    end

    it "is idempotent when coding_checkout_branch is already set" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      branch_before = chat_session.reload.coding_checkout_branch
      path_before = described_class.repo_path_for(chat_session, repository)
      mtime_before = File.stat(path_before.join(".git").to_s).mtime

      described_class.ensure_coding_checkout!(chat_session, repository)

      expect(chat_session.reload.coding_checkout_branch).to eq(branch_before)
      # The .git directory should not have been touched (no re-clone happened)
      expect(File.stat(path_before.join(".git").to_s).mtime).to eq(mtime_before)
    end

    it "replaces an existing shallow checkout with a full clone" do
      shallow_path = described_class.repo_path_for(chat_session, repository)
      FileUtils.mkdir_p(shallow_path.join(".git").to_s)
      File.write(shallow_path.join(".git", "shallow").to_s, "stubbed\n")

      described_class.ensure_coding_checkout!(chat_session, repository)

      expect(shallow_path.join(".git")).to exist
      expect(`git -C #{shallow_path} rev-parse --abbrev-ref HEAD`.strip).to eq("main")
    end

    it "records a repository attachment on the session" do
      described_class.ensure_coding_checkout!(chat_session, repository)

      expect(chat_session.reload.attached_repositories).to include(repository)
    end

    it "enqueues ChatWorkspacePrepareJob after setting up the coding checkout" do
      expect {
        described_class.ensure_coding_checkout!(chat_session, repository)
      }.to have_enqueued_job(ChatWorkspacePrepareJob).with(chat_session.id, repository.id).on_queue("chat")
    end

    it "records prep as queued when setup enqueues asynchronous preparation" do
      described_class.ensure_coding_checkout!(chat_session, repository)

      chat_session.reload
      expect(chat_session.coding_checkout_prepare_status).to eq("queued")
      expect(chat_session.coding_checkout_prepare_started_at).to be_nil
      expect(chat_session.coding_checkout_prepare_finished_at).to be_nil
      expect(chat_session.coding_checkout_prepare_failure).to be_nil
    end

    it "does not enqueue ChatWorkspacePrepareJob when coding checkout is already set" do
      described_class.ensure_coding_checkout!(chat_session, repository)

      expect {
        described_class.ensure_coding_checkout!(chat_session, repository)
      }.not_to have_enqueued_job(ChatWorkspacePrepareJob)
    end

    context "relay credentials" do
      before { ChatWorkspaceRelay.relay_address = "127.0.0.1:9283" }
      after  { ChatWorkspaceRelay.relay_address = nil }

      it "writes coding_relay_address and coding_relay_token when relay is present" do
        described_class.ensure_coding_checkout!(chat_session, repository)

        chat_session.reload
        expect(chat_session.coding_relay_address).to eq("127.0.0.1:9283")
        expect(chat_session.coding_relay_token).to be_present
        expect(chat_session.coding_relay_token.length).to eq(64)
      end

      it "does not overwrite existing relay credentials on a second call" do
        described_class.ensure_coding_checkout!(chat_session, repository)
        original_token = chat_session.reload.coding_relay_token

        described_class.ensure_coding_checkout!(chat_session, repository)

        expect(chat_session.reload.coding_relay_token).to eq(original_token)
      end

      it "does not write relay credentials when relay_address is nil" do
        ChatWorkspaceRelay.relay_address = nil

        described_class.ensure_coding_checkout!(chat_session, repository)

        expect(chat_session.reload.coding_relay_address).to be_nil
        expect(chat_session.reload.coding_relay_token).to be_nil
      end

      it "re-writes relay credentials after a reclaim cleared them" do
        described_class.ensure_coding_checkout!(chat_session, repository)
        described_class.reclaim_coding_checkout!(chat_session)
        chat_session.reload
        expect(chat_session.coding_relay_address).to be_nil

        described_class.ensure_coding_checkout!(chat_session, repository)

        chat_session.reload
        expect(chat_session.coding_relay_address).to eq("127.0.0.1:9283")
        expect(chat_session.coding_relay_token).to be_present
      end
    end
  end

  describe ".ensure_job_branch_checkout!" do
    let(:job_branch) { "syrus/fix-login-42" }

    before do
      # Push a job branch to the bare remote so the clone can check it out.
      Dir.mktmpdir("syrus-chatws-branch-seed") do |tmp|
        sh("git clone -q #{bare_remote_dir} #{tmp}")
        sh("git -C #{tmp} checkout -b #{job_branch}")
        File.write(Pathname.new(tmp).join("feature.txt"), "job feature\n")
        sh("git -C #{tmp} add feature.txt")
        sh("git -C #{tmp} commit -q -m 'job commit' --author='Seed <s@e>'")
        sh("git -C #{tmp} push -q origin #{job_branch}")
      end
    end

    it "clones the repository checked out at the job branch" do
      described_class.ensure_job_branch_checkout!(chat_session, repository, job_branch)

      path = described_class.repo_path_for(chat_session, repository)
      expect(path.join(".git")).to exist
      branch = `git -C #{path} rev-parse --abbrev-ref HEAD`.strip
      expect(branch).to eq(job_branch)
      expect(chat_session.reload.coding_checkout_branch).to eq(job_branch)
    end

    it "is idempotent when coding_checkout_branch already equals the job branch" do
      described_class.ensure_job_branch_checkout!(chat_session, repository, job_branch)
      path = described_class.repo_path_for(chat_session, repository)
      mtime_before = File.stat(path.join(".git").to_s).mtime

      described_class.ensure_job_branch_checkout!(chat_session, repository, job_branch)

      expect(File.stat(path.join(".git").to_s).mtime).to eq(mtime_before)
    end

    it "replaces an existing checkout when called with a different branch" do
      # First set up a regular coding checkout
      described_class.ensure_coding_checkout!(chat_session, repository)
      expect(chat_session.reload.coding_checkout_branch).to eq("main")

      described_class.ensure_job_branch_checkout!(chat_session, repository, job_branch)

      path = described_class.repo_path_for(chat_session, repository)
      expect(`git -C #{path} rev-parse --abbrev-ref HEAD`.strip).to eq(job_branch)
      expect(chat_session.reload.coding_checkout_branch).to eq(job_branch)
    end

    it "records a repository attachment on the session" do
      described_class.ensure_job_branch_checkout!(chat_session, repository, job_branch)

      expect(chat_session.reload.attached_repositories).to include(repository)
    end

    it "enqueues ChatWorkspacePrepareJob after setting up the job branch checkout" do
      expect {
        described_class.ensure_job_branch_checkout!(chat_session, repository, job_branch)
      }.to have_enqueued_job(ChatWorkspacePrepareJob).with(chat_session.id, repository.id).on_queue("chat")
    end

    it "does not enqueue ChatWorkspacePrepareJob when already on the same job branch" do
      described_class.ensure_job_branch_checkout!(chat_session, repository, job_branch)

      expect {
        described_class.ensure_job_branch_checkout!(chat_session, repository, job_branch)
      }.not_to have_enqueued_job(ChatWorkspacePrepareJob)
    end

    it "makes the job branch files accessible in the checkout" do
      described_class.ensure_job_branch_checkout!(chat_session, repository, job_branch)

      path = described_class.repo_path_for(chat_session, repository)
      expect(path.join("feature.txt").read).to include("job feature")
    end
  end

  describe ".uncommitted_changes?" do
    it "returns false for a clean working tree" do
      described_class.attach_repository!(chat_session, repository)
      path = described_class.repo_path_for(chat_session, repository)

      expect(described_class.uncommitted_changes?(path)).to eq(false)
    end

    it "returns true when there is an untracked file" do
      described_class.attach_repository!(chat_session, repository)
      path = described_class.repo_path_for(chat_session, repository)
      File.write(path.join("new_file.txt").to_s, "change\n")

      expect(described_class.uncommitted_changes?(path)).to eq(true)
    end

    it "returns true when there is a modified tracked file" do
      described_class.attach_repository!(chat_session, repository)
      path = described_class.repo_path_for(chat_session, repository)
      File.open(path.join("README.md").to_s, "a") { |f| f.puts "change" }

      expect(described_class.uncommitted_changes?(path)).to eq(true)
    end

    it "returns false for a path with no .git directory" do
      path = Pathname.new("/tmp/not-a-git-repo-#{SecureRandom.hex(4)}")
      expect(described_class.uncommitted_changes?(path)).to eq(false)
    end
  end

  describe ".cancel_coding_checkout!" do
    it "clears default-branch coding checkout state on the session" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      path = described_class.repo_path_for(chat_session, repository)
      expect(`git -C #{path} rev-parse --abbrev-ref HEAD`.strip).to eq("main")

      described_class.cancel_coding_checkout!(chat_session, repository)

      expect(chat_session.reload.coding_checkout_branch).to be_nil
      expect(chat_session.coding_checkout_uncommitted).to eq(false)
      expect(`git -C #{path} rev-parse --abbrev-ref HEAD`.strip).to eq("main")
    end

    it "is a no-op when coding_checkout_branch is not set" do
      expect {
        described_class.cancel_coding_checkout!(chat_session, repository)
      }.not_to raise_error

      expect(chat_session.reload.coding_checkout_branch).to be_nil
    end

    it "clears state even when the checkout directory does not exist" do
      chat_session.update_columns(coding_checkout_branch: "syrus-chat-missing", coding_checkout_uncommitted: true)

      described_class.cancel_coding_checkout!(chat_session, repository)

      expect(chat_session.reload.coding_checkout_branch).to be_nil
      expect(chat_session.coding_checkout_uncommitted).to eq(false)
    end

    it "clears coding_relay_address and coding_relay_token on cancel" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      chat_session.update_columns(
        coding_relay_address: "127.0.0.1:9283",
        coding_relay_token: "tok"
      )

      described_class.cancel_coding_checkout!(chat_session, repository)

      chat_session.reload
      expect(chat_session.coding_relay_address).to be_nil
      expect(chat_session.coding_relay_token).to be_nil
    end
  end

  describe ".file_tree" do
    it "returns a sorted flat file list from the coding checkout" do
      described_class.ensure_coding_checkout!(chat_session, repository)

      result = described_class.file_tree(chat_session, repository)

      expect(result).not_to be_nil
      expect(result[:files]).to be_an(Array)
      expect(result[:files]).to include("README.md")
      expect(result[:checkout_branch]).to eq("main")
    end

    it "excludes .git directory entries" do
      described_class.ensure_coding_checkout!(chat_session, repository)

      result = described_class.file_tree(chat_session, repository)

      expect(result[:files]).not_to include(match(%r{\A\.git/}))
      expect(result[:files]).not_to include(".git")
    end

    it "returns nil when the coding checkout directory does not exist" do
      result = described_class.file_tree(chat_session, repository)

      expect(result).to be_nil
    end

    it "returns the file tree from a selected commit ref" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      checkout_path = described_class.repo_path_for(chat_session, repository)
      initial_sha = sh("git -C #{checkout_path} rev-parse HEAD").strip
      File.write(checkout_path.join("NEW.md").to_s, "# New\n")
      sh("git -C #{checkout_path} add NEW.md")
      sh("git -C #{checkout_path} commit -q -m 'add new file'")

      result = described_class.file_tree(chat_session, repository, ref: initial_sha)

      expect(result).not_to be_nil
      expect(result[:files]).to include("README.md")
      expect(result[:files]).not_to include("NEW.md")
      expect(result[:checkout_branch]).to eq("syrus-chat-#{chat_session.id}")
    end
  end

  describe ".file_content" do
    it "returns the content of an existing file" do
      described_class.ensure_coding_checkout!(chat_session, repository)

      result = described_class.file_content(chat_session, repository, "README.md")

      expect(result).not_to be_nil
      expect(result[:binary]).to eq(false)
      expect(result[:too_large]).to eq(false)
      expect(result[:content]).to include("Widgets")
    end

    it "returns nil for a nonexistent file" do
      described_class.ensure_coding_checkout!(chat_session, repository)

      result = described_class.file_content(chat_session, repository, "no_such_file.rb")

      expect(result).to be_nil
    end

    it "returns nil for path traversal attempts" do
      described_class.ensure_coding_checkout!(chat_session, repository)

      result = described_class.file_content(chat_session, repository, "../../../etc/passwd")

      expect(result).to be_nil
    end

    it "returns nil when the checkout does not exist" do
      result = described_class.file_content(chat_session, repository, "README.md")

      expect(result).to be_nil
    end

    it "returns file content from a selected commit ref" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      checkout_path = described_class.repo_path_for(chat_session, repository)
      initial_sha = sh("git -C #{checkout_path} rev-parse HEAD").strip
      File.write(checkout_path.join("README.md").to_s, "# Changed\n")
      sh("git -C #{checkout_path} add README.md")
      sh("git -C #{checkout_path} commit -q -m 'change readme'")

      result = described_class.file_content(chat_session, repository, "README.md", ref: initial_sha)

      expect(result).not_to be_nil
      expect(result[:content]).to eq("# Widgets\n")
    end
  end

  describe ".coding_diff" do
    it "returns cumulative diff (origin vs working tree) for modified tracked files" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      checkout_path = described_class.repo_path_for(chat_session, repository)
      File.write(checkout_path.join("README.md").to_s, "# Changed\n")

      result = described_class.coding_diff(chat_session, repository, mode: :cumulative)

      expect(result).to include("Changed")
    end

    it "returns turn diff (HEAD vs working tree uncommitted changes)" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      checkout_path = described_class.repo_path_for(chat_session, repository)
      File.write(checkout_path.join("README.md").to_s, "# Turn change\n")

      result = described_class.coding_diff(chat_session, repository, mode: :turn)

      expect(result).to include("Turn change")
    end

    it "returns empty string when checkout does not exist" do
      result = described_class.coding_diff(chat_session, repository, mode: :cumulative)

      expect(result).to eq("")
    end

    it "defaults to cumulative mode" do
      described_class.ensure_coding_checkout!(chat_session, repository)

      result = described_class.coding_diff(chat_session, repository)

      expect(result).to be_a(String)
    end

    it "returns a single-commit diff for a selected ref" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      checkout_path = described_class.repo_path_for(chat_session, repository)
      File.write(checkout_path.join("README.md").to_s, "# Changed\n")
      sh("git -C #{checkout_path} add README.md")
      sh("git -C #{checkout_path} commit -q -m 'change readme'")
      sha = sh("git -C #{checkout_path} rev-parse HEAD").strip

      result = described_class.coding_diff(chat_session, repository, ref: sha)

      expect(result).to include("diff --git a/README.md b/README.md")
      expect(result).to include("+# Changed")
    end
  end

  describe ".coding_commits" do
    it "returns recent checkout commits with safe truncated messages" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      checkout_path = described_class.repo_path_for(chat_session, repository)
      message = "change " + ("x" * 400)
      File.write(checkout_path.join("README.md").to_s, "# Changed\n")
      sh("git -C #{checkout_path} add README.md")
      sh("git -C #{checkout_path} commit -q -m #{Shellwords.escape(message)}")

      result = described_class.coding_commits(chat_session, repository)

      expect(result[:commits].first[:sha]).to match(/\A[0-9a-f]{40}\z/)
      expect(result[:commits].first[:date]).to match(/\A\d{4}-\d{2}-\d{2} /)
      expect(result[:commits].first[:message].bytesize).to be <= described_class::MAX_COMMIT_MESSAGE_BYTES
    end
  end

  describe ".destroy!" do
    it "removes the workspace path" do
      path = described_class.ensure_root!(chat_session)

      described_class.destroy!(chat_session)

      expect(path).not_to exist
    end

    it "removes the per-chat agent homes alongside the workspace" do
      path = described_class.ensure_root!(chat_session)
      agent_home = described_class.agent_home_for(chat_session, "codex")
      FileUtils.mkdir_p(agent_home.to_s)
      FileUtils.touch(agent_home.join("auth.json").to_s)

      described_class.destroy!(chat_session)

      expect(path).not_to exist
      expect(described_class.agent_homes_root_for_id(chat_session.id)).not_to exist
    end

    it "is idempotent on a missing path" do
      described_class.destroy!(chat_session)
      expect(described_class.path_for(chat_session)).not_to exist
    end
  end

  describe ".remove_artifacts_for_id!" do
    it "rejects non-positive ids" do
      expect { described_class.remove_artifacts_for_id!(0) }.to raise_error(ArgumentError)
      expect { described_class.remove_artifacts_for_id!(-3) }.to raise_error(ArgumentError)
    end

    it "ignores recorded workspace paths outside SYRUS_DATA_ROOT" do
      outside = Pathname.new(Dir.mktmpdir("syrus-chatws-outside"))
      FileUtils.touch(outside.join("keep.txt").to_s)

      described_class.remove_artifacts_for_id!(chat_session.id, recorded_workspace_path: outside.to_s)

      expect(outside.join("keep.txt")).to exist
    ensure
      FileUtils.rm_rf(outside.to_s) if outside
    end

    it "never removes the data root itself when it is passed as the recorded path" do
      marker = Pathname.new(@data_root).join("marker.txt")
      FileUtils.touch(marker.to_s)

      described_class.remove_artifacts_for_id!(chat_session.id, recorded_workspace_path: @data_root)

      expect(marker).to exist
    end
  end

  describe ".prune_idle!" do
    it "removes chat workspaces idle past the retention window and clears the path" do
      path = described_class.ensure_root!(chat_session)
      chat_session.update_columns(last_message_at: 8.days.ago, updated_at: 8.days.ago)

      expect(described_class.prune_idle!(older_than: 7.days)).to eq(1)

      expect(path).not_to exist
      expect(chat_session.reload.workspace_path).to be_nil
    end

    it "prunes the per-chat agent homes alongside the idle workspace" do
      described_class.ensure_root!(chat_session)
      agent_home = described_class.agent_home_for(chat_session, "codex")
      FileUtils.mkdir_p(agent_home.to_s)
      chat_session.update_columns(last_message_at: 8.days.ago, updated_at: 8.days.ago)

      expect(described_class.prune_idle!(older_than: 7.days)).to eq(1)

      expect(described_class.agent_homes_root_for_id(chat_session.id)).not_to exist
    end

    it "leaves recently used chat workspaces alone" do
      path = described_class.ensure_root!(chat_session)
      chat_session.update_columns(last_message_at: 1.day.ago)

      expect(described_class.prune_idle!(older_than: 7.days)).to eq(0)

      expect(path).to exist
      expect(chat_session.reload.workspace_path).to eq(path.to_s)
    end
  end

  describe ".sweep_orphans!" do
    it "removes chat-workspace and agent-home directories whose ChatSession no longer exists" do
      root = Pathname.new(@data_root)
      orphan_workspace = root.join("chat-workspaces", "424242")
      orphan_home = root.join("agent_homes", "chats", "424242")
      live_workspace = root.join("chat-workspaces", chat_session.id.to_s)
      live_home = root.join("agent_homes", "chats", chat_session.id.to_s)
      [ orphan_workspace, orphan_home, live_workspace, live_home ].each { |path| FileUtils.mkdir_p(path.to_s) }

      expect(described_class.sweep_orphans!).to eq(2)

      expect(orphan_workspace).not_to exist
      expect(orphan_home).not_to exist
      expect(live_workspace).to exist
      expect(live_home).to exist
    end

    it "skips non-numeric directory names and missing roots" do
      root = Pathname.new(@data_root)
      weird = root.join("chat-workspaces", "not-a-chat-id")
      FileUtils.mkdir_p(weird.to_s)

      expect(described_class.sweep_orphans!).to eq(0)

      expect(weird).to exist
    end
  end

  describe "ChatSession destroy" do
    it "enqueues the worker-side cleanup job instead of removing the workspace inline" do
      path = described_class.ensure_root!(chat_session)
      agent_home = described_class.agent_home_for(chat_session, "codex")
      FileUtils.mkdir_p(agent_home.to_s)
      id = chat_session.id
      workspace_path = chat_session.reload.workspace_path

      expect { chat_session.destroy! }
        .to have_enqueued_job(ChatSessionCleanupJob).with(id, workspace_path).on_queue("chat")

      # The request-side destroy leaves the filesystem alone (the web pod
      # doesn't mount the workspace PVC); the enqueued job does the removal.
      expect(path).to exist

      ChatSessionCleanupJob.perform_now(id, workspace_path)

      expect(path).not_to exist
      expect(described_class.agent_homes_root_for_id(id)).not_to exist
    end
  end

  describe "coding checkout reclaim + restore lifecycle" do
    def coding_path
      described_class.repo_path_for(chat_session, repository)
    end

    def wip_tag_ref
      "refs/tags/syrus-wip/chat-#{chat_session.id}"
    end

    def remote_has_ref?(ref)
      sh("git ls-remote #{bare_remote_dir} #{ref}").strip.present?
    end

    def remote_ref_sha(ref)
      sh("git ls-remote #{bare_remote_dir} #{ref}").split(/\s+/).first
    end

    it "reclaims disk, backs up default-branch commits to a tag, and leaves the session resumable" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      # A committed local change on the default branch is never pushed back to
      # refs/heads/main; the per-chat backup tag carries it across reclaim.
      main_before = remote_ref_sha("refs/heads/main")
      File.write(coding_path.join("feature.rb"), "puts 1\n")
      sh("git -C #{coding_path} add feature.rb")
      sh("git -C #{coding_path} commit -q -m 'add feature'")
      branch = chat_session.reload.coding_checkout_branch

      freed = described_class.reclaim_coding_checkout!(chat_session)

      expect(freed).to be > 0
      expect(coding_path.join(".git")).not_to exist
      expect(remote_ref_sha("refs/heads/main")).to eq(main_before)
      expect(remote_has_ref?(wip_tag_ref)).to be(true)
      expect(chat_session.reload.coding_checkout_branch).to eq(branch)
    end

    it "backs up uncommitted work to a WIP tag before deleting" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      File.write(coding_path.join("README.md"), "# Widgets\nLOCAL WIP\n")
      File.write(coding_path.join("scratch.txt"), "untracked note\n")

      described_class.reclaim_coding_checkout!(chat_session)

      expect(coding_path.join(".git")).not_to exist
      expect(remote_has_ref?(wip_tag_ref)).to be(true)
    end

    it "does not back up a WIP tag when the working tree is clean" do
      described_class.ensure_coding_checkout!(chat_session, repository)

      described_class.reclaim_coding_checkout!(chat_session)

      expect(remote_has_ref?(wip_tag_ref)).to be(false)
    end

    it "transparently re-materializes a reclaimed checkout on the next turn" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      File.write(coding_path.join("feature.rb"), "puts 1\n")
      sh("git -C #{coding_path} add feature.rb")
      sh("git -C #{coding_path} commit -q -m 'add feature'")
      described_class.reclaim_coding_checkout!(chat_session)
      expect(coding_path.join(".git")).not_to exist

      described_class.ensure_coding_checkout!(chat_session, repository)

      expect(coding_path.join(".git")).to exist
      expect(`git -C #{coding_path} rev-parse --abbrev-ref HEAD`.strip)
        .to eq("main")
      # Committed work is back from the backup tag.
      expect(coding_path.join("feature.rb")).to exist
      expect(remote_has_ref?(wip_tag_ref)).to be(false)
    end

    it "restores uncommitted work exactly on re-materialize, then drops the tag" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      File.write(coding_path.join("README.md"), "# Widgets\nLOCAL WIP\n")
      File.write(coding_path.join("scratch.txt"), "untracked note\n")
      described_class.reclaim_coding_checkout!(chat_session)

      described_class.ensure_coding_checkout!(chat_session, repository)

      expect(File.read(coding_path.join("README.md"))).to include("LOCAL WIP")
      expect(coding_path.join("scratch.txt")).to exist
      expect(File.read(coding_path.join("scratch.txt"))).to eq("untracked note\n")
      # The backup tag is consumed once restored.
      expect(remote_has_ref?(wip_tag_ref)).to be(false)
      # No leftover cherry-pick sequencer state — the agent's next commit is normal.
      expect(coding_path.join(".git", "CHERRY_PICK_HEAD")).not_to exist
      # The restored changes read as ordinary uncommitted work (unstaged / untracked).
      expect(`git -C #{coding_path} status --porcelain`.strip).to include("README.md")
    end

    it "preserves the checkout (no data loss) when the backup push fails" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      File.write(coding_path.join("feature.rb"), "puts 1\n")
      allow(repository).to receive(:authenticated_push_url).and_return("file:///nonexistent/repo.git")
      allow_any_instance_of(Repository).to receive(:authenticated_push_url).and_return("file:///nonexistent/repo.git")

      expect {
        described_class.reclaim_coding_checkout!(chat_session)
      }.to raise_error(GitRunner::GitError)

      # The on-disk checkout survives so the uncommitted change isn't lost.
      expect(coding_path.join(".git")).to exist
      expect(coding_path.join("feature.rb")).to exist
    end

    it "reclaim_idle_coding_checkouts! only reclaims sessions idle past the window" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      chat_session.update_columns(last_message_at: 3.days.ago)

      fresh = ChatSession.create!(user: user)
      fresh.update!(repository: repository)
      described_class.ensure_coding_checkout!(fresh, repository)
      fresh.update_columns(last_message_at: 1.hour.ago)
      fresh_path = described_class.repo_path_for(fresh, repository)

      described_class.reclaim_idle_coding_checkouts!(older_than: 48.hours)

      expect(coding_path.join(".git")).not_to exist   # idle → reclaimed
      expect(fresh_path.join(".git")).to exist          # recent → kept
    end

    it "reclaim_coding_over_budget! LRU-evicts the least-recently-active first" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      chat_session.update_columns(last_message_at: 10.days.ago)

      newer = ChatSession.create!(user: user)
      newer.update!(repository: repository)
      described_class.ensure_coding_checkout!(newer, repository)
      newer.update_columns(last_message_at: 1.hour.ago)
      newer_path = described_class.repo_path_for(newer, repository)

      # Budget below the combined size but above one checkout → evict exactly one.
      allow(described_class).to receive(:du_bytes).and_return(10_000_000)
      described_class.reclaim_coding_over_budget!(budget_bytes: 15_000_000)

      expect(coding_path.join(".git")).not_to exist   # oldest evicted
      expect(newer_path.join(".git")).to exist          # newest kept
    end

    it "clears coding_relay_address and coding_relay_token on reclaim" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      chat_session.update_columns(
        coding_relay_address: "127.0.0.1:9283",
        coding_relay_token: "tok"
      )

      described_class.reclaim_coding_checkout!(chat_session)

      chat_session.reload
      expect(chat_session.coding_relay_address).to be_nil
      expect(chat_session.coding_relay_token).to be_nil
    end

    it "prune_idle! never touches a coding checkout (no blind deletion)" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      chat_session.update_columns(last_message_at: 30.days.ago)

      described_class.prune_idle!(older_than: 7.days)

      expect(coding_path.join(".git")).to exist
      expect(chat_session.reload.coding_checkout_branch).to be_present
    end

    it "resets a captured handoff checkout to a clean prepared default-branch baseline" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      File.write(coding_path.join("feature.rb"), "puts 1\n")
      sh("git -C #{coding_path} add feature.rb")
      sh("git -C #{coding_path} commit -q -m 'handoff feature'")
      FileUtils.mkdir_p(coding_path.join("node_modules"))
      File.write(coding_path.join("node_modules", "stale.txt"), "old dependency\n")
      File.write(coding_path.join("scratch.txt"), "old scratch\n")
      chat_session.update_columns(
        coding_checkout_uncommitted: true,
        coding_checkout_prepare_status: "failed",
        coding_checkout_prepare_failure: "old failure"
      )
      add_remote_commit("fresh baseline")
      remote_main = remote_ref_sha("refs/heads/main")

      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      expect {
        described_class.reset_after_coding_handoff!(chat_session, repository)
      }.to have_enqueued_job(ChatWorkspacePrepareJob).with(chat_session.id, repository.id).on_queue("chat")

      expect(`git -C #{coding_path} rev-parse --abbrev-ref HEAD`.strip).to eq("main")
      expect(`git -C #{coding_path} rev-parse HEAD`.strip).to eq(remote_main)
      expect(coding_path.join("README.md").read).to include("fresh baseline")
      expect(coding_path.join("feature.rb")).not_to exist
      expect(coding_path.join("scratch.txt")).not_to exist
      expect(coding_path.join("node_modules", "stale.txt")).not_to exist

      chat_session.reload
      expect(chat_session.coding_checkout_branch).to eq("main")
      expect(chat_session.coding_checkout_uncommitted).to eq(false)
      expect(chat_session.coding_checkout_prepare_status).to eq("queued")
      expect(chat_session.coding_checkout_prepare_failure).to be_nil
    end

    it "reports dirty and committed-ahead status for a coding checkout" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      File.write(coding_path.join("feature.rb"), "puts 1\n")
      sh("git -C #{coding_path} add feature.rb")
      sh("git -C #{coding_path} commit -q -m 'local feature'")
      File.write(coding_path.join("scratch.txt"), "uncommitted\n")

      status = described_class.coding_reset_status(chat_session, repository)

      expect(status).to include(
        path: coding_path.to_s,
        exists: true,
        configured_branch: "main",
        current_branch: "main",
        default_branch: "main",
        dirty: true,
        committed_ahead_count: 1,
        destructive_reset_required: true
      )
      expect(status[:head_sha]).to be_present
      expect(status[:default_branch_sha]).to be_present
    end

    it "refuses to reset dirty or committed-ahead work without confirmation" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      File.write(coding_path.join("feature.rb"), "puts 1\n")
      sh("git -C #{coding_path} add feature.rb")
      sh("git -C #{coding_path} commit -q -m 'local feature'")

      expect {
        described_class.reset_coding_workspace!(chat_session, repository)
      }.to raise_error(ChatWorkspace::ResetRefused, /confirm_discard/)

      expect(coding_path.join("feature.rb")).to exist
      expect(`git -C #{coding_path} rev-list --count origin/main..HEAD`.strip).to eq("1")
    end

    it "resets confirmed abandoned work to a clean default-branch checkout and queues prep" do
      described_class.ensure_coding_checkout!(chat_session, repository)
      File.write(coding_path.join("feature.rb"), "puts 1\n")
      sh("git -C #{coding_path} add feature.rb")
      sh("git -C #{coding_path} commit -q -m 'local feature'")
      File.write(coding_path.join("scratch.txt"), "uncommitted\n")
      chat_session.update_columns(coding_checkout_uncommitted: true)
      add_remote_commit("fresh after abandoned work")
      remote_main = remote_ref_sha("refs/heads/main")

      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      result = nil
      expect {
        result = described_class.reset_coding_workspace!(chat_session, repository, confirm_discard: true)
      }.to have_enqueued_job(ChatWorkspacePrepareJob).with(chat_session.id, repository.id).on_queue("chat")

      expect(result[:before]).to include(destructive_reset_required: true, committed_ahead_count: 1)
      expect(result[:after]).to include(dirty: false, committed_ahead_count: 0, destructive_reset_required: false)
      expect(`git -C #{coding_path} rev-parse HEAD`.strip).to eq(remote_main)
      expect(`git -C #{coding_path} status --porcelain`.strip).to eq("")
      expect(coding_path.join("feature.rb")).not_to exist
      expect(coding_path.join("scratch.txt")).not_to exist
      expect(chat_session.reload.coding_checkout_branch).to eq("main")
      expect(chat_session.coding_checkout_uncommitted).to eq(false)
      expect(chat_session.coding_checkout_prepare_status).to eq("queued")
    end
  end

  def seed_remote(bare_path)
    Dir.mktmpdir("syrus-chatws-seed") do |seed|
      sh("git init -q -b main #{seed}")
      File.write(Pathname.new(seed).join("README.md"), "# Widgets\n")
      sh("git -C #{seed} add README.md")
      sh("git -C #{seed} commit -q -m 'initial' --author='Seed <s@e>'")
      FileUtils.mkdir_p(bare_path.dirname)
      sh("git clone -q --bare #{seed} #{bare_path}")
    end
  end

  def add_remote_commit(text)
    Dir.mktmpdir("syrus-chatws-update") do |seed|
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

  class ChatWorkspaceRecordingGitRunner
    attr_reader :commands

    def initialize
      @commands = []
    end

    def run(*args, **kwargs)
      @commands << { args: args, kwargs: kwargs }
      ""
    end
  end
end
