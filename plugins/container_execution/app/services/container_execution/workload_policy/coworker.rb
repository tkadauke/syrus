module ContainerExecution
  module WorkloadPolicy
    class Coworker < Base
      SENSITIVE_ENV_KEY = /(?:\A|_)(?:authorization|credential|invocation_context|key|lease_id|password|passwd|secret|token)(?:_|\z)/i

      def self.applies_to?(request) = request.workload_policy&.custom_coworker? == true

      def available?
        request.kind.to_s == "agent" &&
          Configuration.mcp_socket_path.present? &&
          egress_policy&.configured? &&
          request.mounts.read_only.empty? && request.mounts.artifacts.nil? &&
          authorized_read_write_mounts?
      end

      def network = Configuration.coworker_network
      def mount_mcp_socket? = true

      def injected_env = egress_policy.proxy_env
      def process_env = safe_env
      def forwarded_env = safe_env

      def extra_run_args
        [
          "--dns", Configuration.coworker_dns,
          "--label", "io.syrus.egress-profile=#{egress_policy.profile}",
          "--read-only", "--user", Configuration.coworker_user,
          "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
          "--security-opt", "seccomp=#{Configuration.seccomp_profile}",
          "--pids-limit", Configuration.coworker_pids_limit.to_s,
          "--memory", Configuration.coworker_memory,
          "--cpus", Configuration.coworker_cpus,
          "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=#{Configuration.coworker_tmpfs_size}"
        ]
      end

      private

      def safe_env
        @safe_env ||= request.env.reject { |key, _value| key.to_s.match?(SENSITIVE_ENV_KEY) }
      end

      def egress_policy
        @egress_policy ||= EgressPolicy::Base.for(request.chat_session&.effective_chat_provider)
      end

      def authorized_read_write_mounts?
        expected_paths = [ request.mounts.workdir, request.env["HOME"] ].compact.map { |path| expanded(path) }
        mounted_paths = request.mounts.read_write.map(&:host_path).map { |path| expanded(path) }
        expected_paths.length == 2 && expected_paths.uniq.length == 2 && mounted_paths.sort == expected_paths.sort
      end

      def expanded(path) = Pathname.new(path.to_s).expand_path.to_s
    end
  end
end
