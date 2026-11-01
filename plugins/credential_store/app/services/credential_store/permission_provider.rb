require "digest"

module CredentialStore
  class PermissionProvider
    include Syrus::Plugin::PermissionProvider

    ROLES = [ AgentRole::CHAT_PLANNER, AgentRole::WORKFLOW_IMPLEMENT ].freeze
    ASK_DEFAULTS = ROLES.index_with { :ask }.freeze

    class << self
      def lookup_credential(identifier, context:)
        credential = Broker.resolve_credential!(
          context: context.fetch(:mcp_context), credential_ref: identifier
        )
        credential if credential.active? && credential.credential_type == SshExec::SSH_PRIVATE_KEY_TYPE
      rescue Broker::Error
        nil
      end

      def normalize_scope(scope, context:)
        source = scope.to_h.with_indifferent_access
        {
          credential: normalize_identifier(source[:credential]),
          host: source[:host].to_s.downcase,
          user: source[:user].to_s,
          port: normalized_port(source[:port])
        }.compact
      end

      def validate_scope(scope, context:)
        errors = []
        errors << "credential is required" if scope["credential"].blank?
        errors << "host is required" if scope["host"].blank?
        errors << "user is required" if scope["user"].blank?
        if scope["port"] && (!scope["port"].is_a?(Integer) || !scope["port"].between?(1, 65_535))
          errors << "port must be between 1 and 65535"
        end
        errors
      end

      def scope_label(scope, context:)
        destination = [ scope["user"], scope["host"] ].join("@")
        destination = "#{destination}:#{scope['port']}" if scope["port"]
        "SSH #{destination}"
      end

      def compare_scopes(left, right, context:)
        return :equal if left == right

        left_path = scope_path(left)
        right_path = scope_path(right)
        return :broader if right_path.first(left_path.length) == left_path
        return :narrower if left_path.first(right_path.length) == right_path

        :disjoint
      end

      def normalize_arguments(arguments)
        source = arguments.to_h.with_indifferent_access
        {
          "credential" => normalize_identifier(source[:credential]),
          "host" => source[:host].to_s.downcase,
          "user" => source[:user].to_s,
          "port" => normalized_port(source[:port]),
          "command_sha256" => source[:command_sha256].presence || Digest::SHA256.hexdigest(source[:command].to_s),
          "allow_unconstrained_host" => source[:allow_unconstrained_host] == true,
          "allow_risky_command" => source[:allow_risky_command] == true
        }.compact
      end

      def redact_arguments(arguments)
        normalize_arguments(arguments).merge("credential" => "[REDACTED CREDENTIAL]")
      end

      def normalize_identifier(value)
        Integer(value, exception: false) || value.to_s
      end

      def normalized_port(value)
        return unless value.present?

        Integer(value, exception: false) || value.to_s
      end

      def scope_path(scope)
        %w[credential host user port].map { |key| scope[key] }.compact
      end
    end

    register_resource_scope(
      :ssh_destination,
      options: { hierarchy: %w[credential host user port] },
      lookup: method(:lookup_credential),
      normalize: method(:normalize_scope),
      validate: method(:validate_scope),
      label: method(:scope_label),
      compare: method(:compare_scopes)
    )

    register_capability(
      capability: "ssh.execute@v1", operation: "ssh.execute/risky@v1",
      effects: %i[network_read confidential_read credential_use external_write privilege_change operational destructive irreversible],
      risk: :critical, requestable_roles: ROLES, defaults: ASK_DEFAULTS,
      maximum_autonomy: :invocation, authority_durations: %i[invocation],
      resource_scope: :ssh_destination, classifier: SshCommandClassification,
      fingerprint_normalizer: method(:normalize_arguments), redactor: method(:redact_arguments)
    )

    register_permission_preset(
      name: "ssh_exact_execution", label: "SSH exact execution",
      description: "Ask for each exact SSH command against a selected credential and destination.",
      rules: [ {
        capability: "ssh.execute@v1", operation: "ssh.execute/risky@v1",
        role: AgentRole::CHAT_PLANNER, policy: :ask, resource_scope: {}, constraints: {}
      } ]
    )
  end
end
