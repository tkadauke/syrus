require "rails_helper"
require "execution/backend_test_kit"
require "socket"
require "tmpdir"

class LocalBackendContractAdapter
  def verify_mount_semantics!
    Dir.mktmpdir("local-backend-mounts") do |dir|
      read_only = File.join(dir, "read-only")
      artifacts = File.join(dir, "artifacts")
      FileUtils.mkdir_p([ read_only, artifacts ])
      runner = ProcessRunner.new(
        env: {}, command: [ "true" ],
        mounts: ProcessRunner.mounts(
          dir, read_only: read_only,
          artifacts: ProcessRunner::Mount.new(host_path: artifacts, mount_path: artifacts)
        ),
        network: "grader", timeout: 5
      )
      writable = ProcessRunner::MountAccess.new(path: File.join(dir, "write"), mode: :write)
      artifact = ProcessRunner::MountAccess.new(path: File.join(artifacts, "result"), mode: :write)
      forbidden = ProcessRunner::MountAccess.new(path: File.join(read_only, "write"), mode: :write)
      runner.send(:mount_access_violation, writable).nil? &&
        runner.send(:mount_access_violation, artifact).nil? &&
        runner.send(:mount_access_violation, forbidden)&.include?("read-only mount")
    end
  end

  def verify_network_profile!
    profile = ProcessRunner::NetworkProfile.for("grader")
    loopback = ProcessRunner::NetworkAccess.new(address: "127.0.0.1", port: 1, family: "AF_INET")
    external = ProcessRunner::NetworkAccess.new(address: "203.0.113.1", port: 1, family: "AF_INET")
    profile.network_access_violation(loopback).nil? && profile.network_access_violation(external).present?
  end

  def verify_resource_limits!
    Dir.mktmpdir("local-backend-cgroup") do |parent|
      feature = Feature.find_or_create_by!(slug: "per_spawn_resource_limits") do |record|
        record.category = "Operations"
        record.name = "Per-spawn resource limits"
      end
      previous_enabled = feature.enabled?
      previous_parent = ENV["SYRUS_SPAWN_CGROUP_PARENT"]
      feature.update!(enabled: true)
      Feature.clear_enabled_cache!("per_spawn_resource_limits")
      ENV["SYRUS_SPAWN_CGROUP_PARENT"] = parent
      File.write(File.join(parent, "cgroup.controllers"), "memory cpu io\n")
      result = ProcessRunner.new(
        env: {}, command: [ RbConfig.ruby, "-e", "exit 0" ], mounts: ProcessRunner.mounts(parent),
        network: "grader", timeout: 5, kind: "grader",
        resource_limits: Execution::BackendTestKit.limits, backend: Execution::Local.new
      ).run
      cgroup = SpawnedProcess.find(result.spawned_process_id).resource_attribution.fetch("cgroup")
      cgroup.values_at("state", "memory_max_bytes", "cpu_max", "io_weight", "cleanup") ==
        [ "applied", 268_435_456, "50000 100000", 200, "removed" ]
    ensure
      previous_parent ? ENV["SYRUS_SPAWN_CGROUP_PARENT"] = previous_parent : ENV.delete("SYRUS_SPAWN_CGROUP_PARENT")
      feature&.update!(enabled: previous_enabled)
      Feature.clear_enabled_cache!("per_spawn_resource_limits")
    end
  end

  def mcp_round_trip(payload)
    Dir.mktmpdir("local-backend-mcp") do |dir|
      socket_path = File.join(dir, "mcp.sock")
      server = UNIXServer.new(socket_path)
      thread = Thread.new do
        client = server.accept
        client.gets == "#{payload}\n" && client.puts(Execution::BackendTestKit::PROBE_REPLY)
        client.close
      end
      output = +""
      result = ProcessRunner.new(
        env: { "SYRUS_PERSISTENT_MCP_SOCKET" => socket_path },
        command: [ RbConfig.ruby, "-rsocket", "-e", mcp_client_script, payload ],
        mounts: ProcessRunner.mounts(dir), network: "grader", timeout: 5,
        on_output_chunk: ->(chunk) { output << chunk }, backend: Execution::Local.new
      ).run
      thread.value
      raise "local MCP probe failed" unless result.success?
      output.strip
    ensure
      server&.close
      thread&.kill if thread&.alive?
    end
  end

  def run(request)
    request = request.with(local_runner: success_runner) if request.is_a?(Execution::Request)
    Execution::Local.new.run(request)
  end

  def fallback(request)
    Execution::Router.new(local: Execution::Local.new).run(request.with(kind: "agent", local_runner: success_runner))
  end

  private

  def success_runner
    Object.new.tap do |runner|
      runner.define_singleton_method(:run_with_local_backend) { Execution::BackendTestKit.success_result }
    end
  end

  def mcp_client_script
    "socket = UNIXSocket.new(ENV.fetch('SYRUS_PERSISTENT_MCP_SOCKET')); " \
      "socket.puts(ARGV.fetch(0)); puts(socket.gets); socket.close"
  end
end

Execution::BackendTestKit.define_examples(RSpec, adapter: ->(_example) { LocalBackendContractAdapter.new })
