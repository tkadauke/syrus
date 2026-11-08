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

      def scope_from_arguments(arguments)
        arguments.to_h.with_indifferent_access.slice(:credential, :host, :user, :port).to_h
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
          "command_prefix" => prefix_matchable_command(source[:command]),
          "allow_unconstrained_host" => source[:allow_unconstrained_host] == true,
          "allow_risky_command" => source[:allow_risky_command] == true
        }.compact
      end

      # The projection a `command_prefix` rule is matched against, and the guard
      # that makes prefix matching safe to offer at all.
      #
      # A prefix rule stands for a family of commands, so it may only ever be
      # matched against a single, plainly tokenized invocation. A command
      # carrying shell syntax -- a semicolon, a pipe, a substitution, a
      # redirect -- is not projected here at all, so no prefix rule can match
      # it and the operator is asked again. That is what stops
      # `git commit -m x; rm -rf /` from satisfying a `git commit` grant: it is
      # not that the prefix fails to match, it is that there is nothing to
      # match against.
      #
      # Tokens are rejoined on single spaces so an operator can read and edit
      # the prefix. One consequence worth knowing: a quoted argument
      # containing spaces flattens into several tokens, so `foo "bar baz"` and
      # `foo bar baz` project alike. Both are the same executable with the
      # same words; a prefix naming them cannot cross into a different command.
      def prefix_matchable_command(command)
        source = command.to_s
        return nil if source.blank?
        return nil if SshExec::RiskyCommandClassifier.unsafe_shell_syntax?(source)

        tokens = Shellwords.split(source)
        return nil if tokens.empty?
        return nil if tokens.any? { |token| dot_command?(token) }

        tokens.join(" ")
      rescue ArgumentError
        nil
      end

      # A prefix grant covers whatever arguments follow it, so it is only ever
      # as narrow as the argument surface of the command named. Several
      # REPL-style tools read a leading-dot word as an instruction to
      # themselves rather than as data, and some of those escape to a shell:
      # `sqlite3 -readonly db ".shell rm -rf /"` runs that command, because
      # -readonly constrains the database and not the interpreter. An operator
      # granting `sqlite3 -readonly <db>` is thinking about queries, so a dot
      # word is not projected and keeps asking.
      #
      # A path is not a dot word: `./deploy.sh` and `../bin/x` stay
      # projectable, because what distinguishes an instruction is a letter
      # directly after the dot.
      def dot_command?(token)
        token.to_s.match?(/\A\.[A-Za-z]/)
      end

      def redact_arguments(arguments)
        source = arguments.to_h.with_indifferent_access
        normalize_arguments(arguments).merge(
          "credential_name" => normalize_identifier(source[:credential]),
          "command" => safe_review_command(source[:command])
          # `command_prefix` is a matching projection, and it is raw: it does not
          # pass through safe_review_command, so leaving it here would print a
          # command's secrets beside the copy that carefully masks them. The
          # reviewable command is already present under "command"; anything an
          # operator reads or edits is derived from that.
        ).except("credential", "command_prefix")
      end

      def safe_review_command(command)
        reviewed = ToolPayloadRedactor.redact_text(command.to_s)
        if reviewed.blank? || reviewed == ToolPayloadRedactor::REDACTED
          raise Mcp::Tools::AuthorizationSupport::AuthorizationError, "SSH command cannot be represented safely for review"
        end
        reviewed
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
      capability: "credential.metadata@v1", operation: "credential.metadata/list@v1",
      effects: %i[confidential_read], risk: :low,
      requestable_roles: ROLES, defaults: ROLES.index_with { :allow },
      maximum_autonomy: :permanent,
      authority_durations: Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS,
      resource_scope: { type: :none },
      classifier: ->(_arguments) { { operation: "credential.metadata/list@v1", effects: %i[confidential_read], risk: :low, confidence: :certain } },
      fingerprint_normalizer: ->(arguments) { arguments.to_h.deep_stringify_keys },
      redactor: ->(arguments) { arguments.to_h.deep_stringify_keys }
    )

    register_capability(
      capability: "ssh.execute@v1", operation: "ssh.execute/read@v1",
      effects: %i[network_read confidential_read credential_use operational],
      risk: :high, requestable_roles: ROLES, defaults: ASK_DEFAULTS,
      maximum_autonomy: :permanent, authority_durations: %i[invocation chat_session permanent],
      resource_scope: :ssh_destination, classifier: SshCommandClassification,
      fingerprint_normalizer: method(:normalize_arguments), redactor: method(:redact_arguments),
      resource_scope_resolver: method(:scope_from_arguments),
      constraint_fields: { command_sha256: :string, command_prefix: :string_prefix,
        allow_unconstrained_host: :boolean, allow_risky_command: :boolean }
    )

    register_capability(
      capability: "ssh.execute@v1", operation: "ssh.execute/risky@v1",
      effects: %i[network_read confidential_read credential_use external_write privilege_change operational destructive irreversible],
      risk: :critical, requestable_roles: ROLES, defaults: ASK_DEFAULTS,
      maximum_autonomy: :permanent, authority_durations: %i[invocation chat_session permanent],
      resource_scope: :ssh_destination, classifier: SshCommandClassification,
      fingerprint_normalizer: method(:normalize_arguments), redactor: method(:redact_arguments),
      resource_scope_resolver: method(:scope_from_arguments),
      constraint_fields: { command_sha256: :string, command_prefix: :string_prefix,
        allow_unconstrained_host: :boolean, allow_risky_command: :boolean }
    )

    register_permission_preset(
      name: "ssh_exact_execution", label: "SSH exact execution",
      description: "Ask for each exact SSH command against a selected credential and destination.",
      rules: %w[ssh.execute/read@v1 ssh.execute/risky@v1].map do |operation|
        { capability: "ssh.execute@v1", operation:,
          role: AgentRole::CHAT_PLANNER, policy: :ask, resource_scope: {}, constraints: {} }
      end
    )
  end
end
