require "pathname"

module ContainerExecution
  module Configuration
    module_function

    def image
      ENV["SYRUS_CONTAINER_EXECUTION_IMAGE"].presence
    end

    def devcontainer_enabled?
      ActiveModel::Type::Boolean.new.cast(ENV["SYRUS_CONTAINER_EXECUTION_DEVCONTAINER"])
    end

    def docker_command
      ENV.fetch("SYRUS_CONTAINER_EXECUTION_DOCKER", "docker")
    end

    def docker_command_path
      command = docker_command.to_s
      return command if command.include?(File::SEPARATOR) && File.executable?(command)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |path|
        candidate = File.join(path, command)
        candidate if File.executable?(candidate)
      end.first
    end

    def docker_socket_path
      ENV.fetch("SYRUS_CONTAINER_EXECUTION_DOCKER_SOCKET", "/var/run/docker.sock")
    end

    # Image tags are reusable only by processes that address the same Docker
    # image store. The worker hostname keeps identical socket paths on separate
    # hosts from being mistaken for one shared daemon. Deployments that route
    # several workers to one remote daemon can give them an explicit common
    # namespace.
    def docker_image_namespace
      ENV["SYRUS_CONTAINER_EXECUTION_DOCKER_NAMESPACE"].presence ||
        "#{SyrusVersion.hostname}:#{ENV['DOCKER_HOST'].presence || docker_socket_path}"
    end

    def docker_transport_available?
      ENV["DOCKER_HOST"].present? || File.socket?(docker_socket_path)
    end

    def mcp_socket_path
      ENV["SYRUS_PERSISTENT_MCP_SOCKET"].presence
    end

    def chat_agent_user = chat_agent_env("USER", "1000:1000")
    def chat_agent_pids_limit = Integer(chat_agent_env("PIDS", "256"))
    def chat_agent_tmpfs_size = chat_agent_env("TMPFS", "256m")
    def chat_agent_memory = chat_agent_env("MEMORY", "4g")
    def chat_agent_cpus = chat_agent_env("CPUS", "2")
    def seccomp_profile = ENV.fetch("SYRUS_CONTAINER_EXECUTION_SECCOMP", "builtin")

    def chat_agent_network = chat_agent_env("NETWORK", nil)
    def chat_agent_dns = chat_agent_env("DNS", nil)

    def chat_agent_proxy_url(provider)
      ENV["SYRUS_CONTAINER_EXECUTION_#{provider.to_s.upcase}_PROXY"].presence
    end

    def host_path_for(path)
      path = Pathname.new(path.to_s).expand_path
      mapping = host_path_mappings
        .select { |container_path, _host_path| under_path?(path, container_path) }
        .max_by { |container_path, _host_path| container_path.to_s.length }
      return nil unless mapping

      container_path, host_path = mapping
      relative = path.relative_path_from(container_path).to_s
      relative == "." ? host_path.to_s : host_path.join(relative).to_s
    end

    def host_path_mappings
      ENV.fetch("SYRUS_CONTAINER_EXECUTION_HOST_PATHS", "").split(",").filter_map do |entry|
        container_path, host_path = entry.split("=", 2).map(&:presence)
        next if container_path.blank? || host_path.blank?

        [ Pathname.new(container_path).expand_path, Pathname.new(host_path).expand_path ]
      end
    end

    def under_path?(path, root)
      relative = path.relative_path_from(root).to_s
      relative == "." || !relative.start_with?("../")
    rescue ArgumentError
      false
    end

    # Reads SYRUS_CONTAINER_EXECUTION_CHAT_AGENT_<key>, falling back to the
    # SYRUS_CONTAINER_EXECUTION_COWORKER_<key> name these settings shipped
    # under. Renaming the Ruby surface should not invalidate configuration an
    # operator has already deployed, so both are read and the new one wins.
    def chat_agent_env(key, fallback)
      ENV["SYRUS_CONTAINER_EXECUTION_CHAT_AGENT_#{key}"].presence ||
        ENV["SYRUS_CONTAINER_EXECUTION_COWORKER_#{key}"].presence ||
        fallback
    end

  end
end
