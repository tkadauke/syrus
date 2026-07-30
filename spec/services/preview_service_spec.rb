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
    it "spawns a process and returns its pid" do
      service = described_class.new
      pid = service.send(:spawn_app, "sleep 60", workspace_path, 28000)
      expect(pid).to be_a(Integer)
      Process.kill("TERM", pid) rescue nil
      Process.waitpid(pid) rescue nil
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

    it "marks the environment failed when no workspace exists" do
      env = create_env(workspace_path: "/nonexistent/path")
      service = described_class.new

      source = instance_double(PreviewCommandSource,
        resolve: PreviewCommandSource::Config.new(
          start_command_for: ->(port:) { "echo #{port}" },
          seed_command: nil,
          health_check_path: "/",
          log_paths: []
        ))
      allow(PreviewCommandSource).to receive(:new).and_return(source)

      service.send(:poll_starting_environments)
      expect(env.reload.state).to eq("starting")
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
