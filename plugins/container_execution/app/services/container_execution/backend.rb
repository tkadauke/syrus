module ContainerExecution
  class Backend < Execution::Backend
    include Syrus::Plugin::ExecutionBackend

    MCP_SOCKET_CONTAINER_PATH = "/run/syrus/mcp.sock".freeze

    def self.available_for?(request)
      request.kind.to_s == "grader" && Configuration.image.present?
    end

    def run(request)
      ProcessRunner.new(
        env: request.env,
        command: docker_command(request),
        mounts: request.mounts,
        network: "grader",
        resource_limits: request.resource_limits,
        timeout: request.timeout,
        stdin_data: request.stdin_data,
        unsetenv_others: request.unsetenv_others,
        pgroup: request.pgroup,
        stop_requested: request.stop_requested,
        on_output_chunk: request.on_output_chunk,
        on_output_line: request.on_output_line,
        kill_grace_seconds: request.kill_grace_seconds,
        silent_timeout: request.silent_timeout,
        kind: request.kind,
        run: request.run,
        workflow: request.workflow,
        job: request.job,
        chat_session: request.chat_session,
        agent: request.agent,
        display_command: request.display_command || request.command.join(" "),
        on_spawned_process: request.on_spawned_process,
        backend: Execution::Local.new
      ).run
    end

    private

    def docker_command(request)
      [
        Configuration.docker_command,
        "run",
        "--rm",
        "--network",
        docker_network(request),
        *resource_limit_args(request.resource_limits),
        *mount_args(request),
        *env_args(request),
        "--workdir",
        container_workdir(request),
        Configuration.image,
        *request.command
      ].compact
    end

    def docker_network(request)
      request.network.to_s == "grader" ? "none" : request.network.to_s
    end

    def mount_args(request)
      args = []
      request.mounts.read_write.each { |mount| args.concat(bind_mount_args(mount, readonly: false)) }
      request.mounts.read_only.each { |mount| args.concat(bind_mount_args(mount, readonly: true)) }
      args.concat(bind_mount_args(request.mounts.artifacts, readonly: false)) if request.mounts.artifacts
      args.concat(mcp_socket_mount_args)
      args
    end

    def bind_mount_args(mount, readonly:)
      options = [
        "type=bind",
        "src=#{mount.host_path}",
        "dst=#{mount.mount_path}"
      ]
      options << "readonly" if readonly
      [ "--mount", options.join(",") ]
    end

    def mcp_socket_mount_args
      socket_path = Configuration.mcp_socket_path
      return [] if socket_path.blank?

      [ "--mount", "type=bind,src=#{socket_path},dst=#{MCP_SOCKET_CONTAINER_PATH},readonly" ]
    end

    def env_args(request)
      request.env.keys.flat_map { |key| [ "--env", key.to_s ] } + mcp_socket_env_args
    end

    def mcp_socket_env_args
      return [] if Configuration.mcp_socket_path.blank?

      [ "--env", "SYRUS_PERSISTENT_MCP_SOCKET=#{MCP_SOCKET_CONTAINER_PATH}" ]
    end

    def resource_limit_args(limits)
      return [] unless limits

      [
        *memory_args(limits),
        *cpu_args(limits),
        *io_args(limits)
      ]
    end

    def memory_args(limits)
      limits.memory_max.present? ? [ "--memory", limits.memory_max.to_s ] : []
    end

    def cpu_args(limits)
      quota, period = limits.cpu_max.to_s.split(/\s+/, 2)
      return [] if quota.blank? || period.blank?

      [ "--cpu-quota", quota, "--cpu-period", period ]
    end

    def io_args(limits)
      limits.io_weight.present? ? [ "--blkio-weight", limits.io_weight.to_s ] : []
    end

    def container_workdir(request)
      matching_mount = request.mounts.declared_mounts.find { |mount| mount.include?(request.chdir) }
      return request.chdir unless matching_mount

      relative = Pathname.new(request.chdir).expand_path
        .relative_path_from(Pathname.new(matching_mount.host_path).expand_path)
        .to_s
      relative == "." ? matching_mount.mount_path : File.join(matching_mount.mount_path, relative)
    end
  end
end
