module ContainerExecution
  module WorkloadPolicy
    class Coworker < Base
      def self.applies_to?(request) = request.workload_policy&.custom_coworker? == true

      def available?
        request.kind.to_s == "agent" &&
          Configuration.mcp_socket_path.present? &&
          request.mounts.read_only.empty? && request.mounts.artifacts.nil? &&
          request.mounts.read_write.length == 2
      end

      # Network allowlisting follows in the network-confinement phase. A
      # private bridge is still preferable to sharing the host namespace.
      def network = "bridge"
      def mount_mcp_socket? = true

      def extra_run_args
        [
          "--read-only", "--user", Configuration.coworker_user,
          "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
          "--security-opt", "seccomp=#{Configuration.seccomp_profile}",
          "--pids-limit", Configuration.coworker_pids_limit.to_s,
          "--memory", Configuration.coworker_memory,
          "--cpus", Configuration.coworker_cpus,
          "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=#{Configuration.coworker_tmpfs_size}"
        ]
      end
    end
  end
end
