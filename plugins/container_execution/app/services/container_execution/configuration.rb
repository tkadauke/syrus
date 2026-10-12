require "pathname"

module ContainerExecution
  module Configuration
    module_function

    def image
      ENV["SYRUS_CONTAINER_EXECUTION_IMAGE"].presence
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

    def docker_transport_available?
      ENV["DOCKER_HOST"].present? || File.socket?(docker_socket_path)
    end

    def mcp_socket_path
      ENV["SYRUS_PERSISTENT_MCP_SOCKET"].presence
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
  end
end
