require "rails_helper"

RSpec.describe PreviewService do
  let(:job) { Factories.job }
  let(:workspace_path) { Dir.mktmpdir }

  after { FileUtils.rm_rf(workspace_path) }

  def create_env(**attrs)
    PreviewEnvironment.create!({
      job: job,
      workspace_path: workspace_path,
      state: "starting"
    }.merge(attrs))
  end

  describe "port allocation" do
    it "allocates a port in the configured range" do
      service = described_class.new
      port = service.send(:allocate_port)
      expect(port).to be_between(PreviewService::PORT_MIN, PreviewService::PORT_MAX)
    end

    it "skips ports already tracked by child processes" do
      service = described_class.new
      occupied = PreviewService::PORT_MIN
      service.instance_variable_get(:@children)[999] =
        PreviewService::ChildProcess.new(pid: 1, environment_id: 999, port: occupied)

      # Stub port_in_use? so only our occupied port returns true
      allow(described_class).to receive(:port_in_use?) do |p|
        p == occupied
      end

      port = service.send(:allocate_port)
      expect(port).not_to eq(occupied)
    end

    it "skips ports used by active database environments" do
      service = described_class.new
      occupied = PreviewService::PORT_MIN
      create_env(state: "running", port: occupied)

      allow(described_class).to receive(:port_in_use?).and_return(false)

      port = service.send(:allocate_port)
      expect(port).not_to eq(occupied)
    end

    it "returns nil when the entire range is occupied" do
      service = described_class.new
      allow(described_class).to receive(:port_in_use?).and_return(true)

      stub_const("PreviewService::PORT_MIN", 30000)
      stub_const("PreviewService::PORT_MAX", 30000)

      port = service.send(:allocate_port)
      expect(port).to be_nil
    end
  end

  describe "child process spawning" do
    it "spawns a process and records a SpawnedProcess audit row" do
      service = described_class.new
      env = create_env

      child = service.send(:spawn_app, "sleep 60", workspace_path, 28000, env)

      expect(child.pid).to be_a(Integer)
      process = SpawnedProcess.find(child.spawned_process_id)
      expect(process).to have_attributes(
        kind: "preview",
        command: "sleep 60",
        workdir: workspace_path
      )
      expect(process.resource_attribution).to include(
        "preview_environment_id" => env.id,
        "job_id" => job.id,
        "port" => 28_000
      )
      Process.kill("TERM", child.pid) rescue nil
      Process.waitpid(child.pid) rescue nil
    end

    it "builds the child process env from the preview config" do
      service = described_class.new
      source = PreviewCommandSource::Config.new(
        start_command_for: ->(port:) { "bin/server -p #{port}" },
        setup_commands:    [],
        seed_command: nil,
        health_check_path: "/",
        log_paths: [],
        env: { "RAILS_ENV" => "development" },
        unset_env: [ "DATABASE_URL" ]
      )

      result = service.send(:preview_process_env, source, workspace_path)
      expect(result).to include(
        "DATABASE_URL" => nil,
        "RAILS_ENV" => "development",
        "BUNDLE_PATH" => File.join(workspace_path, ".syrus/deps/bundle"),
        "BUNDLE_APP_CONFIG" => File.join(workspace_path, ".syrus/deps/bundle-config")
      )
    end

    it "passes preview env to the spawned app" do
      service = described_class.new
      env = create_env
      allow(Process).to receive(:spawn).and_return(12_345)
      allow(Process).to receive(:getpgid).with(12_345).and_return(12_345)

      service.send(:spawn_app, "bin/server", workspace_path, 28_000, env, {
        "DATABASE_URL" => nil,
        "RAILS_ENV" => "development"
      })

      expect(Process).to have_received(:spawn).with(
        { "DATABASE_URL" => nil, "RAILS_ENV" => "development", "PORT" => "28000" },
        "bin/server",
        hash_including(chdir: workspace_path, pgroup: true, unsetenv_others: true)
      )
    end
  end

  describe "health check" do
    it "returns true when the server responds with a 200" do
      service = described_class.new
      ok_response = instance_double(Net::HTTPOK, is_a?: true)
      allow(ok_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(ok_response).to receive(:is_a?).with(Net::HTTPRedirection).and_return(false)
      allow(Net::HTTP).to receive(:start).and_yield(instance_double(Net::HTTP, get: ok_response))
      expect(service.send(:http_ok?, "http://127.0.0.1:28010/")).to be true
    end

    it "returns false when the connection is refused" do
      service = described_class.new
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)
      expect(service.send(:http_ok?, "http://127.0.0.1:1/")).to be false
    end

    it "fails when local health passes but the proxy target cannot reach the preview app" do
      stub_const("PreviewService::INTERNAL_HOST", "preview")
      service = described_class.new
      env = create_env(state: "seeding", port: 28_009)
      child = PreviewService::ChildProcess.new(pid: 12_345, environment_id: env.id, port: 28_009)
      service.instance_variable_get(:@children)[env.id] = child

      allow(Process).to receive(:waitpid2).with(12_345, Process::WNOHANG).and_return(nil)
      allow(Time).to receive(:current).and_return(Time.zone.parse("2026-08-22 12:00:00"))
      allow(service).to receive(:http_ok?) do |url|
        url == "http://127.0.0.1:28009/up"
      end

      expect {
        service.send(:await_health_check, env, 28_009, "/up")
      }.to raise_error(PreviewService::NotReachableError, /not reachable at preview:28009/)
    end

    it "does not require a second health check when the proxy target is loopback" do
      stub_const("PreviewService::INTERNAL_HOST", "127.0.0.1")
      service = described_class.new
      env = create_env(state: "seeding", port: 28_009)
      child = PreviewService::ChildProcess.new(pid: 12_345, environment_id: env.id, port: 28_009)
      service.instance_variable_get(:@children)[env.id] = child

      allow(Process).to receive(:waitpid2).with(12_345, Process::WNOHANG).and_return(nil)
      allow(service).to receive(:http_ok?).with("http://127.0.0.1:28009/up").and_return(true)

      service.send(:await_health_check, env, 28_009, "/up")

      expect(service).to have_received(:http_ok?).once
      expect(env.reload).to be_running
    end
  end

  describe "#workspace_revision_for" do
    it "returns :head for a job that has not landed" do
      service = described_class.new
      expect(service.send(:workspace_revision_for, job)).to eq(:head)
    end

    it "returns :commit_sha for a closed job with a merged commit sha" do
      landed_job = Factories.job_record(state: "closed", landed_sha: "abc123")
      service = described_class.new
      expect(service.send(:workspace_revision_for, landed_job)).to eq(:commit_sha)
    end

    it "returns :head for a closed job with no merged commit sha" do
      closed_job = Factories.job_record(state: "closed", landed_sha: nil)
      service = described_class.new
      expect(service.send(:workspace_revision_for, closed_job)).to eq(:head)
    end

    it "returns :head for a repository-scoped preview (no job)" do
      service = described_class.new
      expect(service.send(:workspace_revision_for, nil)).to eq(:head)
    end
  end

  describe "#poll_starting_environments" do
    it "does not process environments that already have a child entry" do
      env = create_env
      service = described_class.new
      service.instance_variable_get(:@children)[env.id] =
        PreviewService::ChildProcess.new(pid: 99, environment_id: env.id, port: 28001)

      expect(service).not_to receive(:start_environment)
      service.send(:poll_starting_environments)
    end

    it "marks the environment failed when the preview workspace cannot be prepared" do
      env = create_env(workspace_path: "/nonexistent/path")
      service = described_class.new
      allow(PreviewWorkspace).to receive(:prepare!).with(env, revision: :head).and_raise("checkout failed")

      service.send(:poll_starting_environments)
      expect(env.reload.state).to eq("failed")
      expect(env.error_message).to eq("checkout failed")
      expect(env.error_reason).to be_nil
    end

    it "tags the failure with error_reason not_reachable when the proxy target can't reach the app" do
      env = create_env(workspace_path: "/nonexistent/path")
      service = described_class.new
      allow(PreviewWorkspace).to receive(:prepare!).with(env)
        .and_raise(PreviewService::NotReachableError, "preview process is healthy on 127.0.0.1:28009 but is not reachable at preview:28009; configure the preview start command to bind to 0.0.0.0")

      service.send(:poll_starting_environments)
      expect(env.reload.state).to eq("failed")
      expect(env.error_reason).to eq("not_reachable")
      expect(env.error_message).to include("configure the preview start command to bind to 0.0.0.0")
    end

    it "stores the configured internal host for the web proxy target" do
      stub_const("PreviewService::INTERNAL_HOST", "preview")
      env = create_env
      service = described_class.new
      source = instance_double(PreviewCommandSource,
        resolve: PreviewCommandSource::Config.new(
          start_command_for: ->(port:) { "echo #{port}" },
          setup_commands:    [],
          seed_command: nil,
          health_check_path: "/",
          log_paths: [],
          env: {},
          unset_env: []
        ))
      allow(PreviewCommandSource).to receive(:new).and_return(source)
      allow(service).to receive(:allocate_port).and_return(28_008)
      allow(service).to receive(:spawn_app).and_return(
        PreviewService::ChildProcess.new(pid: 12_345, environment_id: env.id, port: 28_008)
      )
      allow(service).to receive(:await_health_check)

      service.send(:poll_starting_environments)

      expect(env.reload.internal_host).to eq("preview")
      expect(env.port).to eq(28_008)
    end

    it "prepares a repository-scoped workspace (no job) with the :head revision" do
      env = PreviewEnvironment.create!(repository: job.repository, workspace_path: "/nonexistent/path", state: "starting")
      service = described_class.new
      allow(PreviewWorkspace).to receive(:prepare!).with(env, revision: :head).and_return(workspace_path)
      source = instance_double(PreviewCommandSource,
        resolve: PreviewCommandSource::Config.new(
          start_command_for: ->(port:) { "echo #{port}" },
          setup_commands: [],
          seed_command: nil,
          health_check_path: "/",
          log_paths: [],
          env: {},
          unset_env: []
        ))
      allow(PreviewCommandSource).to receive(:new).and_return(source)
      allow(service).to receive(:allocate_port).and_return(28_012)
      allow(service).to receive(:spawn_app).and_return(
        PreviewService::ChildProcess.new(pid: 12_345, environment_id: env.id, port: 28_012)
      )
      allow(service).to receive(:await_health_check)

      service.send(:poll_starting_environments)

      expect(PreviewWorkspace).to have_received(:prepare!).with(env, revision: :head)
    end

    it "marks the environment failed when seed exits non-zero and does not spawn the app" do
      env = create_env
      service = described_class.new
      source = instance_double(PreviewCommandSource,
        resolve: PreviewCommandSource::Config.new(
          start_command_for: ->(port:) { "echo #{port}" },
          setup_commands: [],
          seed_command: "bin/seed",
          health_check_path: "/",
          log_paths: [],
          env: {},
          unset_env: []
        ))

      allow(PreviewCommandSource).to receive(:new).and_return(source)
      allow(service).to receive(:allocate_port).and_return(28_008)
      allow(service).to receive(:system)
        .with(anything, "bash", "-c", "bin/seed", chdir: workspace_path, exception: false, unsetenv_others: true)
        .and_return(false)
      expect(service).not_to receive(:spawn_app)

      service.send(:poll_starting_environments)

      expect(env.reload.state).to eq("failed")
      expect(env.error_message).to include("preview seed command exited non-zero")
    end
  end

  describe "seed commands" do
    it "runs configured setup commands before seed/start" do
      service = described_class.new
      source = PreviewCommandSource::Config.new(
        start_command_for: ->(port:) { "bin/server -p #{port}" },
        setup_commands: [ "bundle install", "npm ci" ],
        seed_command: nil,
        health_check_path: "/",
        log_paths: [],
        env: { "RAILS_ENV" => "development" },
        unset_env: []
      )
      process_env = { "RAILS_ENV" => "development" }

      expect(service).to receive(:system)
        .with(process_env, "bash", "-c", "bundle install", chdir: workspace_path, exception: false, unsetenv_others: true)
        .and_return(true)
      expect(service).to receive(:system)
        .with(process_env, "bash", "-c", "npm ci", chdir: workspace_path, exception: false, unsetenv_others: true)
        .and_return(true)

      service.send(:run_setup_commands, source, workspace_path, process_env)
    end

    it "passes preview env to the seed command" do
      service = described_class.new
      source = PreviewCommandSource::Config.new(
        start_command_for: ->(port:) { "bin/server -p #{port}" },
        setup_commands:    [],
        seed_command: "bin/seed",
        health_check_path: "/",
        log_paths: [],
        env: { "RAILS_ENV" => "development" },
        unset_env: [ "DATABASE_URL" ]
      )
      process_env = { "DATABASE_URL" => nil, "RAILS_ENV" => "development" }

      expect(service).to receive(:system)
        .with(process_env, "bash", "-c", "bin/seed", chdir: workspace_path, exception: false, unsetenv_others: true)
        .and_return(true)

      service.send(:run_seed_command, source, workspace_path, process_env)
    end

    it "raises when a seed command exits non-zero" do
      service = described_class.new
      source = PreviewCommandSource::Config.new(
        start_command_for: ->(port:) { "bin/server -p #{port}" },
        setup_commands: [],
        seed_command: "bin/seed",
        health_check_path: "/",
        log_paths: [],
        env: {},
        unset_env: []
      )

      allow(service).to receive(:system).and_return(false)

      expect {
        service.send(:run_seed_command, source, workspace_path, {})
      }.to raise_error(RuntimeError, /preview seed command exited non-zero/)
    end
  end

  describe "TTL expiration" do
    it "stops environments past their expires_at" do
      env = create_env(state: "running", expires_at: 2.minutes.ago, port: 28002)
      service = described_class.new

      expect(service).to receive(:stop_environment) do |e|
        expect(e.id).to eq(env.id)
      end

      service.send(:check_ttl_expirations)
    end

    it "does not stop environments with future expires_at" do
      create_env(state: "running", expires_at: 5.minutes.from_now, port: 28003)
      service = described_class.new

      expect(service).not_to receive(:stop_environment)
      service.send(:check_ttl_expirations)
    end

    it "does not stop environments with no expires_at" do
      create_env(state: "running", expires_at: nil, port: 28004)
      service = described_class.new

      expect(service).not_to receive(:stop_environment)
      service.send(:check_ttl_expirations)
    end
  end

  describe "external stop requests" do
    it "kills tracked children for environments already marked stopping" do
      service = described_class.new
      env = create_env(state: "stopping", port: 28_011)
      service.instance_variable_get(:@children)[env.id] =
        PreviewService::ChildProcess.new(pid: 99_999, environment_id: env.id, port: 28_011)

      expect(service).to receive(:kill_process_group).with(99_999)

      service.send(:poll_stopping_environments)

      expect(env.reload.state).to eq("stopping")
    end

    it "marks already-stopping environments without a tracked child as stopped" do
      service = described_class.new
      env = create_env(state: "stopping", port: 28_011)

      service.send(:poll_stopping_environments)

      expect(env.reload.state).to eq("stopped")
      expect(env.workspace_path).to be_nil
    end

    it "does not spawn the app when stop is requested during setup" do
      env = create_env
      service = described_class.new
      source = instance_double(PreviewCommandSource,
        resolve: PreviewCommandSource::Config.new(
          start_command_for: ->(port:) { "bin/server -p #{port}" },
          setup_commands: [ "bin/setup-preview" ],
          seed_command: nil,
          health_check_path: "/",
          log_paths: [],
          env: {},
          unset_env: []
        ))

      allow(PreviewCommandSource).to receive(:new).and_return(source)
      allow(service).to receive(:allocate_port).and_return(28_011)
      allow(service).to receive(:system) do
        env.reload.begin_stopping!
        env.save!
        true
      end
      expect(service).not_to receive(:spawn_app)

      service.send(:poll_starting_environments)

      expect(env.reload.state).to eq("stopped")
    end
  end

  describe "reaping exited children" do
    it "marks the environment failed when the child exits unexpectedly" do
      service = described_class.new
      env = create_env(state: "running", port: 28005)

      pid = Process.spawn("false")
      Process.waitpid(pid)

      # Inject the dead pid as a tracked child.
      service.instance_variable_get(:@children)[env.id] =
        PreviewService::ChildProcess.new(pid: pid, environment_id: env.id, port: 28005)

      # waitpid2 for a reaped pid will raise ECHILD; stub it to simulate the check.
      allow(Process).to receive(:waitpid2).with(pid, Process::WNOHANG) do
        status = instance_double(Process::Status, success?: false, exitstatus: 1)
        [ pid, status ]
      end

      service.send(:reap_exited_children)

      expect(env.reload.state).to eq("failed")
      expect(env.error_message).to match(/exited unexpectedly/)
    end

    it "finalizes the SpawnedProcess row when a preview child exits" do
      service = described_class.new
      env = create_env(state: "running", port: 28005)
      process = SpawnedProcess.create!(
        kind: "preview",
        command: "sleep 1",
        hostname: "preview-host",
        started_at: Time.current
      )
      pid = Process.spawn("false")
      Process.waitpid(pid)
      service.instance_variable_get(:@children)[env.id] =
        PreviewService::ChildProcess.new(pid: pid, environment_id: env.id, port: 28005, spawned_process_id: process.id)

      allow(Process).to receive(:waitpid2).with(pid, Process::WNOHANG) do
        status = instance_double(Process::Status, success?: false, exitstatus: 1)
        [ pid, status ]
      end

      service.send(:reap_exited_children)

      expect(process.reload).to be_finished
      expect(process.outcome).to eq("failed")
      expect(process.exit_status).to eq(1)
    end

    it "marks the environment stopped when a stopping child exits cleanly" do
      service = described_class.new
      env = create_env(state: "stopping", port: 28006)

      pid = Process.spawn("true")
      Process.waitpid(pid)

      service.instance_variable_get(:@children)[env.id] =
        PreviewService::ChildProcess.new(pid: pid, environment_id: env.id, port: 28006)

      allow(Process).to receive(:waitpid2).with(pid, Process::WNOHANG) do
        status = instance_double(Process::Status, success?: true, exitstatus: 0)
        [ pid, status ]
      end

      service.send(:reap_exited_children)

      expect(env.reload.state).to eq("stopped")
    end
  end

  describe "kill requests" do
    it "stops the preview when its SpawnedProcess kill flag is set" do
      service = described_class.new
      env = create_env(state: "running", port: 28009)
      process = SpawnedProcess.create!(
        kind: "preview",
        command: "bin/rails server",
        hostname: "preview-host",
        started_at: Time.current,
        kill_requested_at: Time.current
      )
      service.instance_variable_get(:@children)[env.id] =
        PreviewService::ChildProcess.new(pid: 99_999, environment_id: env.id, port: 28009, spawned_process_id: process.id)

      expect(service).to receive(:kill_process_group).with(99_999)

      service.send(:honor_kill_requests!)

      expect(env.reload.state).to eq("stopping")
    end
  end

  describe "spawned process reconciliation" do
    it "fails startup immediately when the child exits before health check passes" do
      service = described_class.new
      env = create_env(state: "seeding", port: 28_009)
      process = SpawnedProcess.create!(
        kind: "preview",
        command: "bin/server",
        hostname: "preview-host",
        started_at: Time.current
      )
      child = PreviewService::ChildProcess.new(pid: 12_345, environment_id: env.id, port: 28_009, spawned_process_id: process.id)
      service.instance_variable_get(:@children)[env.id] = child
      status = instance_double(Process::Status, success?: false, exitstatus: 1)

      allow(Process).to receive(:waitpid2).with(12_345, Process::WNOHANG).and_return([ 12_345, status ])

      expect {
        service.send(:await_health_check, env, 28_009, "/up")
      }.to raise_error(RuntimeError, /exited before health check/)

      expect(process.reload.outcome).to eq("failed")
      expect(service.instance_variable_get(:@children)).not_to have_key(env.id)
    end

    it "fails an active preview when its SpawnedProcess is finalized elsewhere" do
      service = described_class.new
      env = create_env(state: "running", port: 28_009)
      process = SpawnedProcess.create!(
        kind: "preview",
        command: "bin/server",
        hostname: "preview-host",
        started_at: 1.minute.ago,
        finished_at: Time.current,
        outcome: "orphaned"
      )
      service.instance_variable_get(:@children)[env.id] =
        PreviewService::ChildProcess.new(pid: 99_999, environment_id: env.id, port: 28_009, spawned_process_id: process.id)

      service.send(:reconcile_finished_spawned_processes!)

      expect(env.reload.state).to eq("failed")
      expect(env.error_message).to include("preview process ended unexpectedly", "orphaned")
      expect(service.instance_variable_get(:@children)).not_to have_key(env.id)
    end

    it "does not fail a preview from an orphaned row when the child pid is still alive" do
      service = described_class.new
      env = create_env(state: "running", port: 28_009)
      process = SpawnedProcess.create!(
        kind: "preview",
        command: "bin/server",
        hostname: "preview-host",
        started_at: 1.minute.ago,
        finished_at: Time.current,
        outcome: "orphaned"
      )
      service.instance_variable_get(:@children)[env.id] =
        PreviewService::ChildProcess.new(pid: 99_999, environment_id: env.id, port: 28_009, spawned_process_id: process.id)
      allow(service).to receive(:process_alive?).with(99_999).and_return(true)

      service.send(:reconcile_finished_spawned_processes!)

      expect(env.reload).to be_running
      expect(service.instance_variable_get(:@children)).to have_key(env.id)
    end
  end

  describe "graceful shutdown" do
    it "sends SIGTERM to all child process groups on shutdown" do
      service = described_class.new
      env = create_env(state: "running", port: 28007)
      env.begin_stopping! && env.save!

      fake_pid = 99999
      service.instance_variable_get(:@children)[env.id] =
        PreviewService::ChildProcess.new(pid: fake_pid, environment_id: env.id, port: 28007)

      kill_calls = []
      allow(Process).to receive(:kill) { |sig, pid| kill_calls << [ sig, pid ] }
      allow(Process).to receive(:waitpid).and_return(nil)

      service.send(:shutdown_gracefully)

      expect(kill_calls).to include([ "-TERM", fake_pid ])
    end
  end
end
