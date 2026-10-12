module ContainerExecution
  module Configuration
    module_function

    def image
      ENV["SYRUS_CONTAINER_EXECUTION_IMAGE"].presence
    end

    def docker_command
      ENV.fetch("SYRUS_CONTAINER_EXECUTION_DOCKER", "docker")
    end

    def mcp_socket_path
      ENV["SYRUS_PERSISTENT_MCP_SOCKET"].presence
    end
  end
end
