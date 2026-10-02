module K8sCluster
  class Kubectl
    CREDENTIAL_TYPE = "k8s_cluster.kubeconfig".freeze
    TOOL_NAME = "k8s_cluster_kubectl".freeze
    MAX_OUTPUT_BYTES = 64.kilobytes

    WRITE_COMMANDS = %w[
      apply
      annotate
      attach
      autoscale
      certificate
      cordon
      cp
      create
      debug
      delete
      drain
      edit
      exec
      expose
      label
      patch
      replace
      rollout
      run
      scale
      set
      taint
      uncordon
    ].freeze
    SECRET_OUTPUT_FORMATS = %w[json yaml jsonpath go-template template].freeze
    FORBIDDEN_FLAGS = %w[--kubeconfig --token --password --username --client-key --client-certificate --certificate-authority].freeze
    FORBIDDEN_FLAG_PREFIXES = FORBIDDEN_FLAGS.map { |flag| "#{flag}=" }.freeze
    FORBIDDEN_CONTEXT_FLAGS = %w[--context --namespace -n].freeze
    FORBIDDEN_CONTEXT_PREFIXES = %w[--context= --namespace=].freeze

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
      raise InvalidCommand, "pass context via kube_context, not kubectl args" if contains_context_flag?
      raise InvalidCommand, "pass namespace via namespace, not kubectl args" if contains_namespace_flag?
      raise InvalidCommand, "kubectl credential flags are not allowed" if contains_forbidden_credential_flag?
      raise RiskyCommand, "kubectl config commands are not allowed" if command == "config"
      raise OperatorConfirmationRequired, "chat kubectl calls cannot self-authorize risky commands" if context.chat? && allow_risky_command
      raise OperatorConfirmationRequired, "chat kubectl calls cannot self-authorize secret output" if context.chat? && allow_secret_output
      raise RiskyCommand, "kubectl command requires explicit risky-command allowance" if risky_command? && !allow_risky_command
      raise RiskyCommand, "kubectl command could expose secret values" if secret_output_command? && !allow_secret_output
    end

    def run_kubectl(kubeconfig_path:, metadata:)
      extra_secrets = sensitive_fragments_from(File.read(kubeconfig_path))
      result = self.class.runner.call(
        env: { "KUBECONFIG" => kubeconfig_path },
        argv: kubectl_argv
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
      normalized_args.any? { |arg| arg == "--namespace" || arg == "-n" || arg.start_with?("--namespace=") }
    end

    def contains_forbidden_credential_flag?
      normalized_args.any? do |arg|
        FORBIDDEN_FLAGS.include?(arg) || FORBIDDEN_FLAG_PREFIXES.any? { |prefix| arg.start_with?(prefix) }
      end
    end

    def risky_command?
      WRITE_COMMANDS.include?(command)
    end

    def secret_output_command?
      return false unless %w[get describe].include?(command)
      return false unless secret_resource?
      return true if command == "describe"

      SECRET_OUTPUT_FORMATS.include?(output_format)
    end

    def secret_resource?
      normalized_args.any? { |arg| %w[secret secrets secret.v1 secrets.v1].include?(arg) }
    end

    def output_format
      normalized_args.each_with_index do |arg, index|
        return arg.split("=", 2).last if arg.start_with?("--output=") || arg.start_with?("-o=")
        return normalized_args[index + 1].to_s if %w[--output -o].include?(arg)
      end
      nil
    end

    def credential_store_enabled?
      defined?(CredentialStore) && CredentialStore.enabled?
    end
  end
end
