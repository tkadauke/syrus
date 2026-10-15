require "cgi"

module K8sCluster
  class Kubectl
    CREDENTIAL_TYPE = "k8s_cluster.kubeconfig".freeze
    TOOL_NAME = "k8s_cluster_kubectl".freeze
    MAX_OUTPUT_BYTES = 64.kilobytes
    RUN_TIMEOUT_SECONDS = 30

    READ_COMMANDS = %w[
      api-resources
      api-versions
      describe
      diff
      events
      explain
      get
      logs
      top
      version
      wait
    ].freeze
    AUTH_READ_COMMANDS = %w[can-i whoami].freeze
    SECRET_RESOURCES = %w[secret secrets].freeze
    SECRET_SAFE_OUTPUT_FORMATS = %w[name].freeze
    STREAMING_COMMANDS = %w[port-forward proxy watch].freeze
    FORBIDDEN_FLAGS = %w[--kubeconfig --token --password --username --client-key --client-certificate --certificate-authority].freeze
    FORBIDDEN_FLAG_PREFIXES = FORBIDDEN_FLAGS.map { |flag| "#{flag}=" }.freeze
    FORBIDDEN_CONTEXT_PREFIXES = %w[--context= --namespace=].freeze
    FORBIDDEN_NAMESPACE_PREFIXES = %w[--namespace= -n].freeze

    class Error < StandardError; end
    class InvalidCommand < Error; end
    class RiskyCommand < Error; end
    class OperatorConfirmationRequired < Error; end
    class PluginDisabled < Error; end
    class PluginDependencyDisabled < Error; end

    class << self
      attr_writer :runner

      def runner
        @runner || KubectlRunner
      end

      def call(context:, credential:, args:, kube_context: nil, cluster: nil, namespace: nil, allow_risky_command: false, allow_secret_output: false)
        new(
          context: context,
          credential: credential,
          args: args,
          kube_context: kube_context,
          cluster: cluster,
          namespace: namespace,
          allow_risky_command: allow_risky_command,
          allow_secret_output: allow_secret_output
        ).call
      end
    end

    def initialize(context:, credential:, args:, kube_context:, cluster:, namespace:, allow_risky_command:, allow_secret_output:)
      @context = context
      @credential = credential
      @args = Array(args).map { |arg| arg.to_s.strip }.reject(&:blank?)
      @kube_context = kube_context.to_s.strip.presence
      @cluster = cluster.to_s.strip.presence
      @namespace = namespace.to_s.strip.presence
      @allow_risky_command = allow_risky_command == true
      @allow_secret_output = allow_secret_output == true
    end

    def call
      validate_inputs!

      CredentialStore::Broker.with_credential_file(
        context: context,
        credential: credential,
        type: CREDENTIAL_TYPE,
        purpose: "kubectl #{command}",
        tool_name: TOOL_NAME,
        target: target,
        credential_validator: method(:credential_denial_reason)
      ) do |kubeconfig_path, metadata|
        run_kubectl(kubeconfig_path: kubeconfig_path, metadata: metadata)
      end
    end

    private

    attr_reader :context, :credential, :args, :kube_context, :cluster, :namespace, :allow_risky_command, :allow_secret_output

    def validate_inputs!
      raise PluginDisabled, "k8s_cluster plugin must be enabled to run credential-backed kubectl" unless K8sCluster.enabled?
      raise PluginDependencyDisabled, "credential_store plugin must be enabled to run credential-backed kubectl" unless credential_store_enabled?
      raise InvalidCommand, "kubectl args must be a non-empty array" if args.empty?
      raise InvalidCommand, "kubectl args cannot include blank values" if args.any?(&:blank?)
      raise InvalidCommand, "kubectl global flags must not precede the subcommand" if leading_global_flag?
      raise InvalidCommand, "omit the kubectl executable from args" if command == "kubectl"
      raise InvalidCommand, "pass context via kube_context, not kubectl args" if contains_context_flag?
      raise InvalidCommand, "pass namespace via namespace, not kubectl args" if contains_namespace_flag?
      raise InvalidCommand, "kubectl credential flags are not allowed" if contains_forbidden_credential_flag?
      raise RiskyCommand, "kubectl command is not in the read-only allowlist" unless allowed_read_command?
      raise RiskyCommand, "streaming or interactive kubectl commands are not allowed" if streaming_command?
      raise OperatorConfirmationRequired, "agent kubectl calls cannot self-authorize secret output" if agent_context? && allow_secret_output
      raise RiskyCommand, "kubectl command could expose secret values" if secret_output_command? && !allow_secret_output
    end

    def run_kubectl(kubeconfig_path:, metadata:)
      extra_secrets = sensitive_fragments_from(File.read(kubeconfig_path))
      result = self.class.runner.call(
        env: {
          "KUBECONFIG" => kubeconfig_path,
          "PATH" => ENV.fetch("PATH", "/usr/local/bin:/usr/bin:/bin"),
          "HOME" => ENV.fetch("HOME", "/tmp")
        },
        argv: kubectl_argv,
        timeout: RUN_TIMEOUT_SECONDS,
        max_output_bytes: MAX_OUTPUT_BYTES
      )

      payload_for(result, metadata: metadata, extra_secrets: extra_secrets)
    rescue StandardError => e
      raise e.class, CredentialStore::Broker.redact(e.message, extra_secrets: extra_secrets || [])
    end

    def payload_for(result, metadata:, extra_secrets:)
      CredentialStore::Broker.redact(
        {
          ok: result.success?,
          status: result.status.to_i,
          stdout: truncate(result.stdout),
          stderr: truncate(result.stderr),
          command: {
            executable: "kubectl",
            args: kubectl_argv.drop(1)
          },
          target: target.compact,
          credential: metadata.except(:safe_metadata),
          safe_metadata: metadata.fetch(:safe_metadata, {}).slice("cluster", "context", "host")
        },
        extra_secrets: extra_secrets
      )
    end

    def sensitive_fragments_from(payload)
      payload.to_s.each_line.filter_map do |line|
        line.match(/\b(?:token|client-key-data|client-certificate-data|certificate-authority-data):\s*(.+?)\s*\z/) { |match| match[1].strip.presence }
      end
    end

    def kubectl_argv
      argv = [ "kubectl" ]
      argv.concat([ "--context", kube_context ]) if kube_context
      argv.concat([ "--namespace", namespace ]) if namespace
      argv.concat(args)
      argv
    end

    def credential_denial_reason(credential)
      registered_cluster = KubernetesCluster.find_by(credential_store_credential_id: credential.id)
      if registered_cluster
        return "agentic access is disabled for this Kubernetes cluster" unless registered_cluster.agentic_access_enabled?
        return "write access is disabled for this Kubernetes cluster" if risky_command? && !registered_cluster.allow_writes?
      end

      metadata = credential.safe_metadata.to_h
      expected_context = metadata["context"].to_s.presence
      expected_cluster = metadata["cluster"].to_s.presence
      expected_namespace = metadata["namespace"].to_s.presence

      return "credential context metadata does not match target" if expected_context && kube_context && expected_context != kube_context
      return "credential requires kube_context" if expected_context && kube_context.blank?
      return "credential cluster metadata does not match target" if expected_cluster && cluster && expected_cluster != cluster
      return "credential namespace metadata does not match target" if expected_namespace && namespace && expected_namespace != namespace

      nil
    end

    def agent_context?
      context.chat? || context.run?
    end

    def target
      {
        kube_context: kube_context,
        kube_cluster: cluster,
        kube_namespace: namespace,
        namespace: namespace
      }.compact
    end

    def truncate(value)
      Mcp::Tools.truncate_text(Mcp::Tools.utf8(value), MAX_OUTPUT_BYTES)
    end

    def command
      args.first.to_s.downcase
    end

    def normalized_args
      @normalized_args ||= args.map(&:downcase)
    end

    def contains_context_flag?
      normalized_args.any? { |arg| FORBIDDEN_CONTEXT_PREFIXES.any? { |prefix| arg.start_with?(prefix) } || arg == "--context" }
    end

    def contains_namespace_flag?
      normalized_args.any? { |arg| arg == "--namespace" || FORBIDDEN_NAMESPACE_PREFIXES.any? { |prefix| arg.start_with?(prefix) } }
    end

    def contains_forbidden_credential_flag?
      normalized_args.any? do |arg|
        FORBIDDEN_FLAGS.include?(arg) || FORBIDDEN_FLAG_PREFIXES.any? { |prefix| arg.start_with?(prefix) }
      end
    end

    def leading_global_flag?
      args.first.to_s.start_with?("-")
    end

    def allowed_read_command?
      return true if READ_COMMANDS.include?(command)

      command == "auth" && AUTH_READ_COMMANDS.include?(normalized_args.second)
    end

    def streaming_command?
      STREAMING_COMMANDS.include?(command) ||
        contains_watch_flag? ||
        (command == "logs" && contains_follow_flag?) ||
        (command == "exec" && contains_interactive_exec_flag?)
    end

    def secret_output_command?
      return false unless %w[get describe].include?(command)
      return true if command == "get" && raw_secret_api_path?
      return false unless secret_resource?
      return true if command == "describe"
      return true if high_verbosity?

      output_formats != SECRET_SAFE_OUTPUT_FORMATS
    end

    def secret_resource?
      normalized_args.any? do |arg|
        arg.split(",").any? do |resource|
          resource_type = resource.split("/", 2).first.to_s.split(".", 2).first
          SECRET_RESOURCES.include?(resource_type)
        end
      end
    end

    def high_verbosity?
      normalized_args.each_with_index.any? do |arg, index|
        value = if %w[-v --v].include?(arg)
          normalized_args[index + 1]
        elsif arg.match?(/\A(?:-v|--v)=/)
          arg.split("=", 2).last
        elsif (match = arg.match(/\A-v(\d+)\z/))
          match[1]
        end

        value.to_i >= 6 if value&.match?(/\A\d+\z/)
      end
    end

    def raw_secret_api_path?
      raw_api_paths.any? do |path|
        path_segments(path).any? { |segment| segment == "secrets" }
      end
    end

    def raw_api_paths
      normalized_args.each_with_index.filter_map do |arg, index|
        if arg.start_with?("--raw=")
          arg.split("=", 2).last
        elsif arg == "--raw"
          normalized_args[index + 1].to_s
        end
      end
    end

    def path_segments(path)
      path.to_s.split(/[?#]/, 2).first.to_s.split("/").filter_map do |segment|
        CGI.unescape(segment).presence
      rescue ArgumentError
        segment.presence
      end
    end

    def output_formats
      normalized_args.each_with_index.filter_map do |arg, index|
        if arg.start_with?("--output=") || arg.start_with?("-o=")
          arg.split("=", 2).last
        elsif arg.start_with?("-o") && arg.length > 2
          arg.delete_prefix("-o")
        elsif %w[--output -o].include?(arg)
          normalized_args[index + 1].to_s
        end
      end
    end

    def contains_watch_flag?
      normalized_args.any? do |arg|
        arg == "-w" || arg == "--watch" || arg == "--watch-only" ||
          arg.start_with?("-w=") || arg.start_with?("--watch=") || arg.start_with?("--watch-only=")
      end
    end

    def contains_follow_flag?
      normalized_args.any? { |arg| arg == "-f" || arg == "--follow" || arg.start_with?("--follow=") }
    end

    def contains_interactive_exec_flag?
      normalized_args.any? { |arg| %w[-i -t -it -ti --stdin --tty].include?(arg) || arg.start_with?("--stdin=") || arg.start_with?("--tty=") }
    end

    def credential_store_enabled?
      defined?(CredentialStore) && CredentialStore.enabled?
    end
  end
end
