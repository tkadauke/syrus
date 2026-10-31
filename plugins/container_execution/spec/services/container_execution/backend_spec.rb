require "rails_helper"
require "socket"
require "tmpdir"
require "execution/backend_test_kit"

RSpec.describe ContainerExecution::Backend do
  around do |example|
    @previous_env = ENV.to_h
    Dir.mktmpdir("container-execution") do |dir|
      @workspace = dir
      @host_workspace = File.join(dir, "host")
      @container_workspace = File.join(dir, "container")
      FileUtils.mkdir_p([ @host_workspace, @container_workspace ])
      example.run
    end
  ensure
    ENV.replace(@previous_env) if @previous_env
    @docker_socket&.close
  end

  it "is only available for grader requests with configured Docker and host-visible mounts" do
    ENV.delete("SYRUS_CONTAINER_EXECUTION_IMAGE")
    expect(described_class.available_for?(request(kind: "grader"))).to be(false)

    configure_container_execution

    expect(described_class.available_for?(request(kind: "agent"))).to be(false)
    expect(described_class.available_for?(request(kind: "grader"))).to be(true)
  end

  it "declines grader requests when Docker cannot be launched" do
    ENV["SYRUS_CONTAINER_EXECUTION_IMAGE"] = "syrus-worker:test"
    ENV["SYRUS_CONTAINER_EXECUTION_DOCKER"] = File.join(@workspace, "missing-docker")
    configure_host_paths
    configure_docker_socket

    expect(described_class.available_for?(request(kind: "grader"))).to be(false)
  end

  it "declines grader requests when Docker transport is not reachable from the worker" do
    ENV["SYRUS_CONTAINER_EXECUTION_IMAGE"] = "syrus-worker:test"
    ENV["SYRUS_CONTAINER_EXECUTION_DOCKER_SOCKET"] = File.join(@workspace, "missing-docker.sock")
    configure_docker_command
    configure_host_paths

    expect(described_class.available_for?(request(kind: "grader"))).to be(false)
  end

  it "declines grader requests when a requested mount has no host path mapping" do
    configure_container_execution(host_paths: "#{@container_workspace}/elsewhere=#{@host_workspace}/elsewhere")

    expect(described_class.available_for?(request(kind: "grader"))).to be(false)
  end

  it "is available without a global image when an opted-in repository declares a devcontainer" do
    configure_container_execution
    ENV.delete("SYRUS_CONTAINER_EXECUTION_IMAGE")
    ENV["SYRUS_CONTAINER_EXECUTION_DEVCONTAINER"] = "true"
    job = instance_double(Job, repository: Object.new)
    allow(ContainerExecution::DevcontainerSpec).to receive(:for_job).with(job).and_return(Object.new)

    expect(described_class.available_for?(request(kind: "grader", job: job))).to be(true)
  end

  it "translates mounts, network policy, resource limits, env, workdir, and the MCP socket into docker run args" do
    configure_container_execution
    backend = described_class.new
    runner = instance_double(ProcessRunner, run: success_result)
    nested = File.join(@container_workspace, "app")
    FileUtils.mkdir_p(nested)
    activity_probe = -> { "active" }
    captured = nil

    expect(ProcessRunner).to receive(:new) do |kwargs|
      captured = kwargs
      runner
    end

    result = backend.run(request(
      chdir: nested,
      mounts: ProcessRunner.mounts(
        @container_workspace,
        read_write: ProcessRunner::Mount.new(host_path: @container_workspace, mount_path: "/workspace"),
        read_only: [ ProcessRunner::Mount.new(host_path: "/opt/cache", mount_path: "/cache") ],
        artifacts: ProcessRunner::Mount.new(
          host_path: File.join(@container_workspace, "artifacts"),
          mount_path: "/artifacts"
        )
      ),
      env: { "CI" => "true" },
      activity_probe: activity_probe,
      resource_limits: Execution::ResourceLimits.new(memory_max: "268435456", cpu_max: "50000 100000", io_weight: 200),
      command: [ "bash", "-c", "bin/rspec" ]
    ))

    expect(result).to be_success
    expect(captured[:backend]).to be_a(Execution::Local)
    expect(captured[:network]).to eq("grader")
    expect(captured[:activity_probe]).to be(activity_probe)
    expect(captured[:command]).to eq([
      fake_docker_path, "run", "--rm",
      "--network", "none",
      "--memory", "268435456",
      "--cpu-quota", "50000",
      "--cpu-period", "100000",
      "--blkio-weight", "200",
      "--mount", "type=bind,src=#{@host_workspace},dst=/workspace",
      "--mount", "type=bind,src=#{@workspace}/cache,dst=/cache,readonly",
      "--mount", "type=bind,src=#{File.join(@host_workspace, "artifacts")},dst=/artifacts",
      "--mount", "type=bind,src=#{@host_workspace}/mcp.sock,dst=/run/syrus/mcp.sock,readonly",
      "--env", "CI",
      "--env", "SYRUS_PERSISTENT_MCP_SOCKET=/run/syrus/mcp.sock",
      "--workdir", "/workspace/app",
      "syrus-worker:test",
      "bash", "-c", "bin/rspec"
    ])
  end

  %w[codex claude muse agy].each do |provider|
    it "confines #{provider} coworker turns to the checkout, provider home, tmpfs, and MCP socket" do
      configure_container_execution(host_paths: "#{@container_workspace}=#{@host_workspace}")
      agent_home = File.join(@container_workspace, "agent-home-#{provider}")
      FileUtils.mkdir_p(agent_home)
      policy = instance_double(Coworkers::ExecutionWorkloadPolicy, custom_coworker?: true, fail_closed?: true, name: "custom coworker")
      runner = instance_double(ProcessRunner, run: success_result)
      captured = nil
      allow(ProcessRunner).to receive(:new) { |kwargs| captured = kwargs; runner }

      configure_coworker_egress(provider)
      chat = instance_double(ChatSession, effective_chat_provider: provider)
      coworker_request = request(
        kind: "agent", network: "agent", chat_session: chat,
        workload_policy: policy,
        mounts: ProcessRunner.agent_mounts(@container_workspace, agent_home),
        env: {
          "HOME" => agent_home, "PROVIDER" => provider,
          "HTTPS_PROXY" => "http://unsafe-host-proxy:8080",
          "https_proxy" => "http://unsafe-host-proxy:8080",
          "no_proxy" => "169.254.169.254"
        }
      )

      expect(described_class.available_for?(coworker_request)).to be(true)
      described_class.new.run(coworker_request)
      command = captured.fetch(:command)
      mounts = command.each_index.filter_map { |index| command[index + 1] if command[index] == "--mount" }

      expect(command).to include("--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
        "--security-opt", "seccomp=builtin", "--pids-limit", "256", "--memory", "4g", "--cpus", "2")
      expect(command).to include("--network", "syrus-coworker-egress", "--dns", "192.0.2.53",
        "--label", "io.syrus.egress-profile=#{provider}")
      expect(command).to include("--env", "HTTPS_PROXY=http://egress-proxy:3128",
        "--env", "https_proxy=http://egress-proxy:3128", "--env", "NO_PROXY=", "--env", "no_proxy=")
      expect(command).not_to include("HTTPS_PROXY", "HTTPS_PROXY=http://unsafe-host-proxy:8080",
        "https_proxy", "https_proxy=http://unsafe-host-proxy:8080", "no_proxy", "no_proxy=169.254.169.254")
      expect(command).to include("--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=256m")
      expect(mounts).to contain_exactly(
        "type=bind,src=#{@host_workspace},dst=#{@container_workspace}",
        "type=bind,src=#{File.join(@host_workspace, "agent-home-#{provider}")},dst=#{agent_home}",
        "type=bind,src=#{@host_workspace}/mcp.sock,dst=/run/syrus/mcp.sock,readonly"
      )
      expect(command).to include("--env", "SYRUS_PERSISTENT_MCP_SOCKET=/run/syrus/mcp.sock")
      expect(mounts.join(" ")).not_to match(%r{/(?:workflows|agent_homes)/(?![^ ]*agent-home-#{provider})})
    end
  end

  it "fails closed when the provider egress profile is not configured" do
    configure_container_execution(host_paths: "#{@container_workspace}=#{@host_workspace}")
    agent_home = File.join(@container_workspace, "agent-home")
    FileUtils.mkdir_p(agent_home)
    policy = instance_double(Coworkers::ExecutionWorkloadPolicy, custom_coworker?: true)
    chat = instance_double(ChatSession, effective_chat_provider: "codex")
    coworker_request = request(kind: "agent", chat_session: chat, workload_policy: policy,
      mounts: ProcessRunner.agent_mounts(@container_workspace, agent_home), env: { "HOME" => agent_home })

    expect(described_class.available_for?(coworker_request)).to be(false)
  end

  it "rejects coworker requests whose writable mounts are not the checkout and declared provider home" do
    configure_container_execution(host_paths: "#{@container_workspace}=#{@host_workspace}")
    agent_home = File.join(@container_workspace, "agent-home")
    other_workspace = File.join(@container_workspace, "other-workspace")
    FileUtils.mkdir_p([ agent_home, other_workspace ])
    policy = instance_double(Coworkers::ExecutionWorkloadPolicy, custom_coworker?: true)
    unsafe_mounts = ProcessRunner.mounts(
      @container_workspace,
      read_write: [ @container_workspace, other_workspace ]
    )

    unsafe_request = request(
      kind: "agent", workload_policy: policy, mounts: unsafe_mounts,
      env: { "HOME" => agent_home }
    )

    expect(described_class.available_for?(unsafe_request)).to be(false)
  end

  def configure_container_execution(host_paths: nil)
    ENV["SYRUS_CONTAINER_EXECUTION_IMAGE"] = "syrus-worker:test"
    configure_docker_command
    configure_docker_socket
    configure_host_paths(host_paths)
    ENV["SYRUS_PERSISTENT_MCP_SOCKET"] = "#{@container_workspace}/mcp.sock"
  end

  def configure_coworker_egress(provider)
    ENV["SYRUS_CONTAINER_EXECUTION_COWORKER_NETWORK"] = "syrus-coworker-egress"
    ENV["SYRUS_CONTAINER_EXECUTION_COWORKER_DNS"] = "192.0.2.53"
    ENV["SYRUS_CONTAINER_EXECUTION_#{provider.upcase}_PROXY"] = "http://egress-proxy:3128"
  end

  def configure_docker_command
    File.write(fake_docker_path, "#!/bin/sh\n")
    FileUtils.chmod(0o755, fake_docker_path)
    ENV["SYRUS_CONTAINER_EXECUTION_DOCKER"] = fake_docker_path
  end

  def configure_docker_socket
    socket_path = File.join(@workspace, "docker.sock")
    @docker_socket&.close
    @docker_socket = UNIXServer.new(socket_path)
    ENV["SYRUS_CONTAINER_EXECUTION_DOCKER_SOCKET"] = socket_path
  end

  def configure_host_paths(host_paths = nil)
    ENV["SYRUS_CONTAINER_EXECUTION_HOST_PATHS"] = host_paths || [
      "#{@container_workspace}=#{@host_workspace}",
      "/opt/cache=#{@workspace}/cache"
    ].join(",")
  end

  def fake_docker_path
    File.join(@workspace, "docker")
  end

  def request(overrides = {})
    defaults = {
      env: {},
      command: [ "true" ],
      chdir: @container_workspace,
      mounts: ProcessRunner.mounts(@container_workspace),
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

class ContainerBackendContractAdapter
  def initialize(example)
    @example = example
    ENV["SYRUS_CONTAINER_EXECUTION_IMAGE"] = "syrus-worker:test"
    ENV["SYRUS_CONTAINER_EXECUTION_HOST_PATHS"] = "/host=/host"
    ENV["SYRUS_PERSISTENT_MCP_SOCKET"] = "/host/mcp.sock"
  end

  def verify_mount_semantics!
    command, = capture(probe_request)
    mounts = values_after(command, "--mount")
    mounts.include?("type=bind,src=/host/work,dst=/work") &&
      mounts.include?("type=bind,src=/host/cache,dst=/cache,readonly") &&
      mounts.include?("type=bind,src=/host/artifacts,dst=/artifacts")
  end

  def verify_network_profile!
    command, = capture(probe_request)
    value_after(command, "--network") == "none"
  end

  def verify_resource_limits!
    command, = capture(probe_request(resource_limits: Execution::BackendTestKit.limits))
    value_after(command, "--memory") == "268435456" &&
      value_after(command, "--cpu-quota") == "50000" &&
      value_after(command, "--cpu-period") == "100000" &&
      value_after(command, "--blkio-weight") == "200"
  end

  def mcp_round_trip(payload)
    Dir.mktmpdir("container-backend-mcp") do |dir|
      socket_path = File.join(dir, "mcp.sock")
      ENV["SYRUS_PERSISTENT_MCP_SOCKET"] = socket_path
      ENV["SYRUS_CONTAINER_EXECUTION_HOST_PATHS"] = "/host=/host,#{dir}=#{dir}"
      server = UNIXServer.new(socket_path)
      thread = Thread.new do
        client = server.accept
        client.gets == "#{payload}\n" && client.puts(Execution::BackendTestKit::PROBE_REPLY)
        client.close
      end
      command, = capture(probe_request)
      socket_mount = values_after(command, "--mount").find { |value| value.include?("dst=/run/syrus/mcp.sock") }
      raise "MCP socket was not mounted read-only" unless socket_mount&.end_with?(",readonly")
      raise "MCP endpoint was not advertised" unless values_after(command, "--env")
        .include?("SYRUS_PERSISTENT_MCP_SOCKET=/run/syrus/mcp.sock")

      source = socket_mount.split(",").find { |field| field.start_with?("src=") }.delete_prefix("src=")
      client = UNIXSocket.new(source)
      client.puts(payload)
      reply = client.gets&.strip
      client.close
      thread.value
      reply
    ensure
      server&.close
      thread&.kill if thread&.alive?
      ENV["SYRUS_PERSISTENT_MCP_SOCKET"] = "/host/mcp.sock"
      ENV["SYRUS_CONTAINER_EXECUTION_HOST_PATHS"] = "/host=/host"
    end
  end

  def run(request)
    _, result = capture(request)
    result
  end

  def fallback(request)
    raise "container backend unexpectedly accepted a non-grader request" if ContainerExecution::Backend.available_for?(request.with(kind: "agent"))

    local = Object.new
    local.define_singleton_method(:run) { |_value| Execution::BackendTestKit.success_result }
    Execution::Router.new(local: local).run(request.with(kind: "agent"))
  end

  private

  def capture(request)
    command = nil
    runner = @example.instance_double(ProcessRunner, run: Execution::BackendTestKit.success_result)
    @example.allow(ProcessRunner).to @example.receive(:new) do |kwargs|
      command = kwargs.fetch(:command)
      runner
    end
    result = ContainerExecution::Backend.new.run(request)
    [ command, result ]
  end

  def probe_request(**overrides)
    mounts = ProcessRunner::Mounts.new(
      workdir: "/host/work",
      read_write: ProcessRunner::Mount.new(host_path: "/host/work", mount_path: "/work"),
      read_only: ProcessRunner::Mount.new(host_path: "/host/cache", mount_path: "/cache"),
      artifacts: ProcessRunner::Mount.new(host_path: "/host/artifacts", mount_path: "/artifacts")
    )
    Execution::BackendTestKit.request(**{ chdir: "/host/work", mounts: mounts }.merge(overrides))
  end

  def values_after(command, flag)
    command.each_index.filter_map { |index| command[index + 1] if command[index] == flag }
  end

  def value_after(command, flag) = command[command.index(flag) + 1]
end

Execution::BackendTestKit.define_examples(
  RSpec,
  adapter: ->(example) { ContainerBackendContractAdapter.new(example) }
)
