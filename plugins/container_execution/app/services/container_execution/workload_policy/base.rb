module ContainerExecution
  module WorkloadPolicy
    class Base
      def self.resolve(request)
        policies.find { |policy| policy.applies_to?(request) }&.new(request)
      end

      def self.policies = [ Coworker, Grader ]

      attr_reader :request

      def initialize(request) = @request = request
      def available? = true
      def network = "none"
      def extra_run_args = []
      def mount_mcp_socket? = false
    end
  end
end
