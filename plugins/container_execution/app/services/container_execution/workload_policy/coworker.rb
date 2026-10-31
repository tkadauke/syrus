module ContainerExecution
  module WorkloadPolicy
    class Coworker < Base
      def self.applies_to?(request) = request.workload_policy&.custom_coworker? == true

      def available?
        request.kind.to_s == "agent" &&
          Configuration.mcp_socket_path.present? &&
          request.mounts.read_only.empty? && request.mounts.artifacts.nil? &&
          authorized_read_write_mounts?
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

      private

      def authorized_read_write_mounts?
        expected_paths = [ request.mounts.workdir, request.env["HOME"] ].compact.map { |path| expanded(path) }
        mounted_paths = request.mounts.read_write.map(&:host_path).map { |path| expanded(path) }
        expected_paths.length == 2 && expected_paths.uniq.length == 2 && mounted_paths.sort == expected_paths.sort
      end

      def expanded(path) = Pathname.new(path.to_s).expand_path.to_s
    end
  end
end
