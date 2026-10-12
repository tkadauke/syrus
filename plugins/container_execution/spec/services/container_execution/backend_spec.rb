require "rails_helper"
require "tmpdir"

RSpec.describe ContainerExecution::Backend do
  around do |example|
    @previous_env = ENV.to_h
    Dir.mktmpdir("container-execution") do |dir|
      @workspace = dir
      example.run
    end
  ensure
    ENV.replace(@previous_env) if @previous_env
  end

  it "is only available for grader requests with a configured image" do
    ENV.delete("SYRUS_CONTAINER_EXECUTION_IMAGE")
    expect(described_class.available_for?(request(kind: "grader"))).to be(false)

    ENV["SYRUS_CONTAINER_EXECUTION_IMAGE"] = "syrus-worker:test"
    expect(described_class.available_for?(request(kind: "agent"))).to be(false)
    expect(described_class.available_for?(request(kind: "grader"))).to be(true)
  end

  it "translates mounts, network policy, resource limits, env, workdir, and the MCP socket into docker run args" do
    ENV["SYRUS_CONTAINER_EXECUTION_IMAGE"] = "syrus-worker:test"
    ENV["SYRUS_CONTAINER_EXECUTION_DOCKER"] = "/usr/local/bin/docker"
    ENV["SYRUS_PERSISTENT_MCP_SOCKET"] = "/tmp/syrus-mcp.sock"
    backend = described_class.new
    runner = instance_double(ProcessRunner, run: success_result)
    nested = File.join(@workspace, "app")
    FileUtils.mkdir_p(nested)
    captured = nil

    expect(ProcessRunner).to receive(:new) do |kwargs|
      captured = kwargs
      runner
    end

    result = backend.run(request(
      chdir: nested,
      mounts: ProcessRunner.mounts(
        @workspace,
        read_write: ProcessRunner::Mount.new(host_path: @workspace, mount_path: "/workspace"),
        read_only: [ ProcessRunner::Mount.new(host_path: "/opt/cache", mount_path: "/cache") ],
        artifacts: ProcessRunner::Mount.new(host_path: File.join(@workspace, "artifacts"), mount_path: "/artifacts")
      ),
      env: { "CI" => "true" },
      resource_limits: Execution::ResourceLimits.new(memory_max: "268435456", cpu_max: "50000 100000", io_weight: 200),
      command: [ "bash", "-c", "bin/rspec" ]
    ))

    expect(result).to be_success
    expect(captured[:backend]).to be_a(Execution::Local)
    expect(captured[:network]).to eq("grader")
    expect(captured[:command]).to eq([
      "/usr/local/bin/docker", "run", "--rm",
      "--network", "none",
      "--memory", "268435456",
      "--cpu-quota", "50000",
      "--cpu-period", "100000",
      "--blkio-weight", "200",
      "--mount", "type=bind,src=#{@workspace},dst=/workspace",
      "--mount", "type=bind,src=/opt/cache,dst=/cache,readonly",
      "--mount", "type=bind,src=#{File.join(@workspace, "artifacts")},dst=/artifacts",
      "--mount", "type=bind,src=/tmp/syrus-mcp.sock,dst=/run/syrus/mcp.sock,readonly",
      "--env", "CI",
      "--env", "SYRUS_PERSISTENT_MCP_SOCKET=/run/syrus/mcp.sock",
      "--workdir", "/workspace/app",
      "syrus-worker:test",
      "bash", "-c", "bin/rspec"
    ])
  end

  def request(overrides = {})
    defaults = {
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
      kill_grace_seconds: ProcessRunner::TERM_GRACE_SECONDS,
      silent_timeout: nil,
      kind: "grader",
      run: nil,
      workflow: nil,
      job: nil,
      chat_session: nil,
      agent: nil,
      display_command: nil,
      on_spawned_process: nil,
      local_runner: nil
    }
    Execution::Request.new(**defaults.merge(overrides))
  end

  def success_result
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
  end
end
