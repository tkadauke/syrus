require "rails_helper"
require "tmpdir"

RSpec.describe Steps::Prepare do
  # Build a Run wired to a workflow + step so the handler's
  # `workspace`, `log`, `repository`, `job` accessors all work.
  let(:job)      { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step)     { workflow.steps.first.tap { |s| s.update!(kind: "prepare") } }
  let(:run)      { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:handler)  { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-prepare") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    # Stub the workspace so we don't actually clone anything; the
    # handler's `workspace.path` returns our tmpdir.
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  it "no-ops cleanly when there are no commands to run" do
    # Empty workspace → auto-detect finds nothing → empty plan
    expect { handler.call }.not_to raise_error

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("no commands to run")
    expect(workflow.reload.artifact("prepare_failure")).to be_nil
    expect(step.reload.details["prepare_failure"]).to be_nil
  end

  it "runs each command from .syrus.yml in order" do
    File.write(@ws_path.join(".syrus.yml"), <<~YAML)
      prepare:
        - echo first
        - echo second
    YAML

    handler.call

    chunks = run.reload.job_logs.pluck(:chunk)
    # Ordered: announcement of cmd1, output, announcement of cmd2, output
    cmd_announces = chunks.select { |c| c.include?("$ echo") }
    expect(cmd_announces.size).to eq(2)
    expect(cmd_announces.first).to include("(1/2) $ echo first")
    expect(cmd_announces.last).to include("(2/2) $ echo second")
    expect(chunks.join("\n")).to include("first")
    expect(chunks.join("\n")).to include("second")
    expect(chunks.last).to include("all commands completed successfully")
    expect(workflow.reload.artifact("prepare_failure")).to be_nil
    expect(step.reload.details["prepare_failure"]).to be_nil
  end

  it "auto-detects bundle install on a Gemfile-bearing repo" do
    File.write(@ws_path.join("Gemfile"), "")
    # Stub bash so we don't actually run bundle in the test sandbox
    allow(handler).to receive(:run_shell) do |cmd, **|
      run.job_logs.create!(sequence: (run.job_logs.maximum(:sequence) || -1) + 1,
                           chunk: "[stub-ran] #{cmd}")
      true
    end

    handler.call

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("source: auto-detect (Gemfile)")
    expect(chunks).to include("[stub-ran] bundle install")
  end

  it "runs commands with workspace-local dependency paths" do
    File.write(@ws_path.join(".syrus.yml"), <<~YAML)
      prepare:
        - bundle install
    YAML
    old_bundle_without = ENV["BUNDLE_WITHOUT"]
    ENV["BUNDLE_WITHOUT"] = "development:test"
    captured_env = nil
    fake_runner = instance_double(ProcessRunner)
    allow(fake_runner).to receive(:run).and_return(
      ProcessRunner::Result.new(
        exit_status: 0,
        timed_out: false,
        stopped: false,
        silent_timed_out: false,
        operator_killed: false,
        aliveness_failed: false,
        duration_s: 0.1,
        spawned_process_id: nil
      )
    )
    allow(ProcessRunner).to receive(:new) do |*_, **kwargs|
      captured_env = kwargs.fetch(:env)
      fake_runner
    end

    handler.call

    deps = @ws_path.join(".syrus", "deps")
    expect(captured_env).to include(
      "BUNDLE_PATH" => deps.join("bundle").to_s,
      "BUNDLE_APP_CONFIG" => deps.join("bundle-config").to_s,
      "BUNDLE_USER_HOME" => deps.join("bundle-home").to_s,
      "BUNDLE_USER_CACHE" => deps.join("bundle-cache").to_s,
      "NPM_CONFIG_CACHE" => deps.join("npm-cache").to_s,
      "YARN_CACHE_FOLDER" => deps.join("yarn-cache").to_s,
      "COREPACK_HOME" => deps.join("corepack").to_s
    )
    expect(captured_env).not_to have_key("BUNDLE_WITHOUT")
  ensure
    ENV["BUNDLE_WITHOUT"] = old_bundle_without
  end

  it "raises StepFailed when a prepare command exits non-zero" do
    File.write(@ws_path.join(".syrus.yml"), <<~YAML)
      prepare:
        - bash -c 'printf "alpha\\\\nbeta\\\\n"; exit 7'
    YAML
    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /exit 7.*Output tail/m)

    failure = workflow.reload.artifact("prepare_failure")
    expect(failure).to include(
      "command" => "bash -c 'printf \"alpha\\\\nbeta\\\\n\"; exit 7'",
      "workdir" => @ws_path.to_s,
      "exit_status" => 7,
      "timed_out" => false,
      "output_tail" => include("alpha", "beta")
    )
    expect(step.reload.details["prepare_failure"]).to eq(failure)

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("[prepare] failure: prepare command failed (exit 7)")
    expect(chunks).to include("alpha")
    expect(chunks).to include("beta")
    # Explicit commands are hard failures, never tagged soft.
    expect(workflow.reload.artifact("prepare_failure")).not_to include("soft")
  end

  it "soft-fails a guessed (auto-detected) command instead of aborting the chain" do
    # No .syrus.yml: the Gemfile drives auto-detect → `bundle install`,
    # which Syrus only guessed. A non-zero exit must NOT raise, so the
    # agent still gets to run (and can add a .syrus.yml or fix the repo).
    File.write(@ws_path.join("Gemfile"), "")
    fake_runner = instance_double(ProcessRunner)
    allow(fake_runner).to receive(:run).and_return(
      ProcessRunner::Result.new(
        exit_status: 7,
        timed_out: false,
        stopped: false,
        silent_timed_out: false,
        operator_killed: false,
        aliveness_failed: false,
        duration_s: 0.1,
        spawned_process_id: nil
      )
    )
    allow(ProcessRunner).to receive(:new).and_return(fake_runner)

    expect { handler.call }.not_to raise_error

    failure = workflow.reload.artifact("prepare_failure")
    expect(failure).to include(
      "command" => "bundle install",
      "exit_status" => 7,
      "soft" => true
    )
    expect(step.reload.details["prepare_failure"]).to eq(failure)

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("source: auto-detect (Gemfile)")
    expect(chunks).to include("WARNING (guessed command, non-fatal)")
    expect(chunks).to include("handing off to the agent without it")
    # The success line must NOT print — setup did not complete.
    expect(chunks).not_to include("all commands completed successfully")
  end

  describe "fork sync" do
    let(:upstream) { Factories.repository(owner: "upstream-org", name: "upstream-project") }
    let(:fork_repo) do
      Factories.repository(
        owner: "fork-user",
        name: "forked-project",
        upstream_repository: upstream
      )
    end
    let(:fork_job) { Factories.job(repository: fork_repo) }
    let(:fork_workflow) { fork_job.workflows.last }
    let(:fork_step) do
      fork_workflow.steps.first.tap { |s| s.update!(kind: "prepare") }
    end
    let(:fork_run) do
      fork_step.runs.first ||
        fork_step.runs.create!(job: fork_job, trigger_kind: fork_workflow.trigger_kind)
    end
    let(:syrus_branch) { "syrus/direct-#{fork_job.id}" }
    let(:fork_handler) { described_class.new(fork_run) }
    let(:git) { instance_double(GitRunner) }
    let(:sha_git) { instance_double(GitRunner) }
    let(:fake_client) { instance_double(GithubClient, access_token: "test-token") }
    let(:push_url) { "https://x-access-token:test-token@github.com/fork-user/forked-project.git" }

    before do
      fork_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path, branch_name: syrus_branch)
      allow(fork_handler).to receive(:workspace).and_return(fork_ws)
      allow(fork_handler).to receive(:streaming_git).and_return(git)
      allow(GitRunner).to receive(:new).and_return(sha_git)
      allow(GithubClient).to receive(:for).and_return(fake_client)
      allow(fork_repo).to receive(:authenticated_push_url).with("test-token").and_return(push_url)
      allow(git).to receive(:run)
      # sha_before differs from sha_after by default (new commits merged from upstream)
      allow(sha_git).to receive(:run).and_return("sha-before\n", "sha-after\n")
    end

    it "skips fork sync when repository has no upstream" do
      # The outer `handler` uses a plain repository without an upstream
      handler.call
      chunks = run.reload.job_logs.pluck(:chunk).join
      expect(chunks).not_to include("fork sync")
    end

    it "fetches upstream, merges into fork default, pushes, and fast-forwards the syrus branch" do
      fork_handler.call

      expect(git).to have_received(:run).with("fetch", upstream.remote_url, upstream.default_branch, chdir: @ws_path.to_s)
      expect(git).to have_received(:run).with("checkout", fork_repo.default_branch, chdir: @ws_path.to_s)
      expect(git).to have_received(:run).with("merge", "--no-edit", "FETCH_HEAD", chdir: @ws_path.to_s)
      expect(git).to have_received(:run).with("push", push_url, "HEAD:refs/heads/#{fork_repo.default_branch}", chdir: @ws_path.to_s)
      expect(git).to have_received(:run).with("checkout", syrus_branch, chdir: @ws_path.to_s)
      expect(git).to have_received(:run).with("merge", "--ff-only", fork_repo.default_branch, chdir: @ws_path.to_s)

      artifact = fork_workflow.reload.artifact("fork_sync")
      expect(artifact).to include(
        "upstream_slug" => upstream.slug,
        "upstream_branch" => upstream.default_branch,
        "fork_default_branch" => fork_repo.default_branch,
        "already_up_to_date" => false
      )
      expect(artifact["synced_at"]).to be_present
    end

    it "skips push and records already_up_to_date when fork is already current" do
      allow(sha_git).to receive(:run).and_return("same-sha\n")

      fork_handler.call

      expect(git).not_to have_received(:run).with("push", anything, anything, hash_including(:chdir))
      artifact = fork_workflow.reload.artifact("fork_sync")
      expect(artifact).to include("already_up_to_date" => true)
      chunks = fork_run.reload.job_logs.pluck(:chunk).join
      expect(chunks).to include("already up-to-date")
    end

    it "raises StepFailed and records fork_sync_failure artifact on merge conflict" do
      merge_error = GitRunner::GitError.new(["merge"], 1, "CONFLICT (content): Merge conflict in app.rb")
      allow(git).to receive(:run) do |*args, **_kwargs|
        raise merge_error if args[0] == "merge" && args[1] == "--no-edit"
        ""
      end

      expect { fork_handler.call }.to raise_error(Steps::Base::StepFailed, /fork sync.*merge conflict/i)

      failure = fork_workflow.reload.artifact("fork_sync_failure")
      expect(failure).to include(
        "upstream_slug" => upstream.slug,
        "upstream_branch" => upstream.default_branch
      )
      expect(fork_workflow.artifact("fork_sync")).to be_nil
    end

    it "aborts the in-progress merge and restores the syrus branch on conflict" do
      merge_error = GitRunner::GitError.new(["merge"], 1, "CONFLICT")
      git_commands = []
      allow(git).to receive(:run) do |*args, **_kwargs|
        git_commands << args.dup
        raise merge_error if args[0] == "merge" && args[1] == "--no-edit"
        ""
      end

      fork_handler.call rescue nil

      expect(git_commands).to include(["merge", "--abort"])
      expect(git_commands.last).to eq(["checkout", syrus_branch])
    end

    it "continues without error when syrus branch cannot fast-forward (follow-up workflow)" do
      ff_error = GitRunner::GitError.new(["merge", "--ff-only"], 1, "Not possible to fast-forward")
      allow(git).to receive(:run) do |*args, **_kwargs|
        raise ff_error if args[0] == "merge" && args[1] == "--ff-only"
        ""
      end

      expect { fork_handler.call }.not_to raise_error

      chunks = fork_run.reload.job_logs.pluck(:chunk).join
      expect(chunks).to include("has existing commits")
      expect(fork_workflow.reload.artifact("fork_sync")).not_to be_nil
    end

    context "when job has an owner_user set" do
      let(:owner_user) { Factories.user(github_token: "owner-ghp-token") }
      # Override fork_job so owner_user is set before fork_handler is initialized
      let(:fork_job) { Factories.job(repository: fork_repo, owner_user: owner_user) }
      let(:owner_push_url) { "https://push-as-owner.example/" }

      before do
        owner_client = instance_double(GithubClient, access_token: "owner-token")
        allow(GithubClient).to receive(:for).with(repository: fork_repo, user: owner_user).and_return(owner_client)
        allow(fork_repo).to receive(:authenticated_push_url).with("owner-token").and_return(owner_push_url)
      end

      it "uses owner_user credentials for the fork push rather than job.user" do
        fork_handler.call

        expect(fork_repo).to have_received(:authenticated_push_url).with("owner-token")
        expect(git).to have_received(:run).with("push", owner_push_url, anything, hash_including(:chdir))
      end
    end
  end

  describe "mise install" do
    let(:success_result) do
      ProcessRunner::Result.new(
        exit_status: 0, timed_out: false, stopped: false,
        silent_timed_out: false, operator_killed: false,
        aliveness_failed: false, duration_s: 0.5, spawned_process_id: nil
      )
    end

    let(:failure_result) do
      ProcessRunner::Result.new(
        exit_status: 1, timed_out: false, stopped: false,
        silent_timed_out: false, operator_killed: false,
        aliveness_failed: false, duration_s: 0.5, spawned_process_id: nil
      )
    end

    it "skips mise install when no version files are present" do
      # Empty workspace: no lockfiles and no version files → nothing runs
      handler.call

      chunks = run.reload.job_logs.pluck(:chunk).join("\n")
      expect(chunks).not_to include("mise install")
      expect(workflow.reload.artifact("mise_install_failure")).to be_nil
    end

    Steps::Prepare::MISE_VERSION_FILES.each do |version_file|
      it "detects #{version_file} and runs mise install" do
        File.write(@ws_path.join(version_file), "ruby 3.4.0\n")
        fake_runner = instance_double(ProcessRunner, run: success_result)
        allow(ProcessRunner).to receive(:new).and_return(fake_runner)

        handler.call

        expect(ProcessRunner).to have_received(:new).with(
          hash_including(command: [ "mise", "install" ], timeout: Steps::Prepare::MISE_INSTALL_TIMEOUT)
        )
        expect(workflow.reload.artifact("mise_install_failure")).to be_nil
      end
    end

    context "when a version file is present" do
      before { File.write(@ws_path.join(".tool-versions"), "ruby 3.4.0\n") }

      it "runs mise install in the workspace directory with the scrubbed env" do
        captured_kwargs = nil
        fake_runner = instance_double(ProcessRunner, run: success_result)
        allow(ProcessRunner).to receive(:new) do |**kwargs|
          captured_kwargs = kwargs if kwargs[:command] == [ "mise", "install" ]
          fake_runner
        end

        handler.call

        expect(captured_kwargs).to include(
          command: [ "mise", "install" ],
          chdir: @ws_path,
          timeout: Steps::Prepare::MISE_INSTALL_TIMEOUT
        )
        # Env must come from the scrubbed PREP_ENV_FORWARD list, not the raw worker env
        expect(captured_kwargs[:env]).not_to have_key("BUNDLE_WITHOUT")
        expect(captured_kwargs[:env]).not_to have_key("RAILS_ENV")
      end

      it "soft-fails when mise install exits non-zero — records artifact and continues" do
        fake_runner = instance_double(ProcessRunner, run: failure_result)
        allow(ProcessRunner).to receive(:new).and_return(fake_runner)

        expect { handler.call }.not_to raise_error

        failure = workflow.reload.artifact("mise_install_failure")
        expect(failure).to include(
          "command" => "mise install",
          "exit_status" => 1,
          "soft" => true
        )
        expect(step.reload.details["mise_install_failure"]).to eq(failure)

        chunks = run.reload.job_logs.pluck(:chunk).join("\n")
        expect(chunks).to include("[prepare] WARNING (mise install, non-fatal)")
      end

      it "soft-fails when mise install times out — records artifact and continues" do
        timed_out_result = ProcessRunner::Result.new(
          exit_status: nil, timed_out: true, stopped: false,
          silent_timed_out: false, operator_killed: false,
          aliveness_failed: false, duration_s: Steps::Prepare::MISE_INSTALL_TIMEOUT.to_f,
          spawned_process_id: nil
        )
        fake_runner = instance_double(ProcessRunner, run: timed_out_result)
        allow(ProcessRunner).to receive(:new).and_return(fake_runner)

        expect { handler.call }.not_to raise_error

        failure = workflow.reload.artifact("mise_install_failure")
        expect(failure).to include("soft" => true, "timed_out" => true)

        chunks = run.reload.job_logs.pluck(:chunk).join("\n")
        expect(chunks).to include("[prepare] WARNING (mise install, non-fatal)")
        expect(chunks).to include("timed out after")
      end
    end
  end

  describe "#stream_buffered" do
    it "coalesces a 640 KB burst instead of flushing each byte-threshold chunk" do
      data = 40.times.map { |i| i.to_s.rjust(4, "0") + ("x" * (16 * 1024 - 4)) }.join

      stream(data)

      logs = run.job_logs.order(:sequence).pluck(:chunk)
      expect(logs.count).to be <= 2
      expect(logs.join).to eq(data)
    end

    it "forces flushes at LOG_FLUSH_MAX_BUF during sustained high-rate output" do
      data = 3.times.map { |i| i.to_s.rjust(4, "0") + ("x" * (Steps::Base::LOG_FLUSH_MAX_BUF - 4)) }.join

      freeze_time do
        stream(data)
      end

      logs = run.job_logs.order(:sequence).pluck(:chunk)
      expect(logs.count).to eq(3)
      expect(logs.all? { |chunk| chunk.bytesize >= Steps::Base::LOG_FLUSH_MAX_BUF }).to be(true)
      expect(logs.join).to eq(data)
    end

    def stream(data)
      reader, writer = IO.pipe
      writer_thread = Thread.new do
        writer.write(data)
        writer.close
      end

      handler.send(:stream_buffered, reader)
      writer_thread.join
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
    end
  end
end
