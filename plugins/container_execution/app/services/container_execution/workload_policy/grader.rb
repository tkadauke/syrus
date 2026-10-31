module ContainerExecution
  module WorkloadPolicy
    class Grader < Base
      def self.applies_to?(request) = request.kind.to_s == "grader"
      def mount_mcp_socket? = true
    end
  end
end
