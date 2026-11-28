module ContainerExecution
  module WorkloadPolicy
    # Governs every chat agent turn, not coworkers specifically: containment is
    # an operator switch (AppSetting#contained_chat_execution), and the risk it
    # addresses comes from what an agent is granted and whether anyone is
    # watching, not from which kind of chat it belongs to.
    class ChatAgent < Base
      WORKSPACE_PATH = "/workspace".freeze
      PROVIDER_HOME_PATH = "/home/coworker".freeze
      SENSITIVE_ENV_KEY = /(?:\A|_)(?:authorization|credential|invocation_context|key|lease_id|password|passwd|secret|token)(?:_|\z)/i

      def self.applies_to?(request) = request.workload_policy&.chat_agent? == true

      def available?
        request.kind.to_s == "agent" &&
          Configuration.mcp_socket_path.present? &&
          mount_profile.present? &&
          egress_policy&.configured? &&
          request.mounts.read_only.empty? && request.mounts.artifacts.nil? &&
          authorized_read_write_mounts? && authorized_workdir?
      end

      def network = Configuration.chat_agent_network
      def mount_mcp_socket? = true

      def injected_env
        egress_policy.proxy_env.merge(
          "HOME" => PROVIDER_HOME_PATH,
          "TMPDIR" => "/tmp",
          "SYRUS_WORKSPACE" => WORKSPACE_PATH,
          "SYRUS_MCP_SOCKET" => Backend::MCP_SOCKET_CONTAINER_PATH
        )
      end
      def process_env = safe_env
      def forwarded_env = safe_env

      def extra_run_args
        [
          "--dns", Configuration.chat_agent_dns,
          "--label", "io.syrus.egress-profile=#{egress_policy.profile}",
          "--read-only", "--user", Configuration.chat_agent_user,
          "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
          "--security-opt", "seccomp=#{Configuration.seccomp_profile}",
          "--pids-limit", Configuration.chat_agent_pids_limit.to_s,
          "--memory", Configuration.chat_agent_memory,
          "--cpus", Configuration.chat_agent_cpus,
          *mount_profile.tmpfs_args
        ]
      end

      def mount_path_for(mount)
        return WORKSPACE_PATH if expanded(mount.host_path) == expanded(request.mounts.workdir)
        return PROVIDER_HOME_PATH if expanded(mount.host_path) == expanded(request.env["HOME"])

        raise ArgumentError, "chat agent mount is outside the fixed mount contract"
      end

      def container_workdir(_default)
        workspace = Pathname.new(request.mounts.workdir).expand_path
        relative = Pathname.new(request.chdir).expand_path.relative_path_from(workspace).to_s
        relative == "." ? WORKSPACE_PATH : File.join(WORKSPACE_PATH, relative)
      end

      private

      def safe_env
        @safe_env ||= request.env.reject { |key, _value| key.to_s.match?(SENSITIVE_ENV_KEY) }
      end

      def egress_policy
        @egress_policy ||= EgressPolicy::Base.for(request.chat_session&.effective_chat_provider)
      end

      def mount_profile
        @mount_profile ||= MountProfile::Base.for(Configuration.chat_agent_mount_profile)
      end

      def authorized_read_write_mounts?
        expected_paths = [ request.mounts.workdir, request.env["HOME"] ].compact.map { |path| expanded(path) }
        mounted_paths = request.mounts.read_write.map(&:host_path).map { |path| expanded(path) }
        expected_paths.length == 2 && expected_paths.uniq.length == 2 && mounted_paths.sort == expected_paths.sort
      end

      def authorized_workdir?
        workspace = Pathname.new(request.mounts.workdir).expand_path
        relative = Pathname.new(request.chdir).expand_path.relative_path_from(workspace).to_s
        relative == "." || (relative != ".." && !relative.start_with?("../"))
      rescue ArgumentError
        false
      end

      def expanded(path) = Pathname.new(path.to_s).expand_path.to_s
    end
  end
end
