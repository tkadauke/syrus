require "rails_helper"
require "tmpdir"

RSpec.describe Execution::Router do
  around do |example|
    snapshot = Syrus::PluginRegistry.snapshot
    Dir.mktmpdir("execution-router") do |dir|
      @workspace = dir
      example.run
    end
  ensure
    Syrus::PluginRegistry.restore(snapshot)
    PluginRecord.where(name: %w[accepting_execution_backend declining_execution_backend]).delete_all
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  it "instantiates the first enabled provider that accepts the request" do
    configure_backend("test_backend")
    backend = Class.new do
      include Syrus::Plugin::ExecutionBackend

      def self.backend_name = "test_backend"

      def self.available_for?(_request) = true

      def run(_request)
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
      end
    end
    Syrus::PluginRegistry.register(
      name: "accepting_execution_backend",
      version: "1.0.0",
      provides: { execution_backend: backend }
    )

    result = described_class.new.run(request)

    expect(result.exit_status).to eq(7)
  end

  it "uses the local fallback when no enabled provider accepts the request" do
    configure_backend("test_backend")
    local = instance_double(Execution::Local, run: :local_result)
    backend = Class.new do
      include Syrus::Plugin::ExecutionBackend

      def self.backend_name = "test_backend"

      def self.available_for?(_request) = false
      def run(_request) = raise("should not run")
    end
    Syrus::PluginRegistry.register(
      name: "declining_execution_backend",
      version: "1.0.0",
      provides: { execution_backend: backend }
    )

    expect(described_class.new(local: local).run(request)).to eq(:local_result)
  end

  it "fails closed when a workload forbids local execution" do
    policy = double(name: "chat agent", fail_closed?: true)

    expect { described_class.new.run(request.with(workload_policy: policy)) }
      .to raise_error(Execution::Router::BackendUnavailable, /chat agent/)
  end

  # The distinction the contained_chat_execution setting rests on. Core's own
  # contract promises a local fallback when no provider applies; a policy that
  # merely *prefers* containment must not revoke that promise, because the
  # container backend is plugin-provided and ships disabled. Wiring a hard
  # requirement to it took every coworker chat turn down on an instance where
  # the plugin was off.
  it "falls back to local when a workload prefers containment but does not require it" do
    local = instance_double(Execution::Local, run: :local_result)
    policy = double(name: "chat agent", fail_closed?: false)

    expect(described_class.new(local: local).run(request.with(workload_policy: policy))).to eq(:local_result)
  end

  it "uses the local fallback when the repository does not select a backend" do
    local = instance_double(Execution::Local, run: :local_result)
    backend = Class.new do
      include Syrus::Plugin::ExecutionBackend

      def self.backend_name = "test_backend"
      def self.available_for?(_request) = true
      def run(_request) = raise("should not run")
    end
    Syrus::PluginRegistry.register(
      name: "accepting_execution_backend",
      version: "1.0.0",
      provides: { execution_backend: backend }
    )

    expect(described_class.new(local: local).run(request)).to eq(:local_result)
  end

  it "supports directly registered provider instances" do
    configure_backend("test_backend")
    backend = Class.new do
      include Syrus::Plugin::ExecutionBackend

      def self.backend_name = "test_backend"

      def run(_request)
        :direct_result
      end
    end.new
    Syrus::PluginRegistry.register(:execution_backend, backend)

    expect(described_class.new.run(request)).to eq(:direct_result)
  end

  def request
    Execution::Request.new(
      env: {},
      command: [ "true" ],
      chdir: @workspace,
      mounts: ProcessRunner.mounts(@workspace),
      network: "grader",
      resource_limits: nil,
      timeout: 5,
      stdin_data: nil,
      unsetenv_others: true,
      pgroup: true,
      stop_requested: -> { false },
      on_output_chunk: nil,
      on_output_line: nil,
      activity_probe: nil,
      kill_grace_seconds: ProcessRunner::TERM_GRACE_SECONDS,
      silent_timeout: nil,
      activity_probe: nil,
      kind: "grader",
      run: nil,
      workflow: nil,
      job: nil,
      chat_session: nil,
      agent: nil,
      display_command: nil,
      on_spawned_process: nil,
      workload_policy: nil,
      local_runner: nil
    )
  end

  def configure_backend(name)
    File.write(File.join(@workspace, ".syrus.yml"), "execution:\n  grader_backend: #{name}\n")
  end
end
