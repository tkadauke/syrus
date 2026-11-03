require "digest"
require "pathname"

module Permissions
  # Stable capability contract for the Local Mode tools that act on the
  # operator's own machine: +run_command+ and +write_file+.
  #
  # Both operations live under +syrus.local_mode@v1+ and carry the
  # +operator_host_access+ effect. The classifier narrows each invocation from
  # the arguments themselves and only ever adds effects:
  #
  # - network use (+network_read+, plus +external_write+ for pushes),
  # - credential use (+credential_use+) for secrets, keys, and env dumps,
  # - destructive or privileged work (+destructive+, +privilege_change+).
  #
  # The descriptor declares just +operator_host_access+, and a lease only
  # covers invocations whose effects it lists. An invocation that picks up any
  # extra effect is therefore never covered by a chat-session or invocation
  # lease: it asks every time (see +LocalModeAuthorization+).
  #
  # Authority is bound to the workspace the daemon is attached to (the
  # resource scope), to the normalized command or path (fingerprint and lease
  # constraints), and to the Chat Session (lifecycle). Leases are ordinary
  # +PermissionLease+ rows, so they show up in the permissions hub and can be
  # revoked there. The daemon keeps enforcing the repository-root sandbox; this
  # layer only decides whether the call may be dispatched.
  class LocalModeActions
    CAPABILITY = "syrus.local_mode@v1".freeze
    TOOL_NAMES = %w[run_command write_file].freeze
    ROLES = [ AgentRole::CHAT_LOCAL ].freeze

    NETWORK_COMMAND = /(?:\A|[\s;&|(])(?:curl|wget|ssh|scp|sftp|rsync|nc|ncat|telnet|ftp|ping|dig|nslookup|npm\s+(?:install|i|ci|publish)|yarn\s+(?:add|install)|pnpm\s+(?:add|install)|pip3?\s+install|gem\s+install|bundle\s+install|brew\s+install|apt(?:-get)?\s+install|docker\s+pull|git\s+(?:clone|fetch|pull|push|ls-remote|remote\s+update))\b/
    PUSH_COMMAND = /(?:\A|[\s;&|(])(?:git\s+push|npm\s+publish|gem\s+push|docker\s+push)\b/
    CREDENTIAL_COMMAND = %r{(?:~|\$HOME|/home/[^/\s]+|/Users/[^/\s]+)?/?\.(?:ssh|aws|gnupg|netrc|npmrc|pypirc|kube|docker/config\.json)|\.env\b|id_(?:rsa|ed25519|ecdsa)|credentials|secrets?\b|\btoken\b|(?:\A|[\s;&|(])(?:printenv|env|export\s+-p|security\s+find-\w+-password|gh\s+auth\s+token)(?:\s|\z)}i
    DESTRUCTIVE_COMMAND = /(?:\A|[\s;&|(])(?:rm\s+-\w*[rf]|git\s+(?:reset\s+--hard|clean|checkout\s+--|push\s+.*--force|push\s+-f)|mkfs|dd\s+|truncate|shred|chmod\s+-R|chown\s+-R|kill\s+-9|pkill|killall)\b|>\s*\/(?!dev\/null)/
    PRIVILEGED_COMMAND = /(?:\A|[\s;&|(])(?:sudo|su|doas)\s/

    PROTECTED_PATH_PATTERNS = {
      credential_use: [ %r{(?:\A|/)\.env(?:\.[\w-]+)?\z}, %r{(?:\A|/)\.(?:ssh|aws|gnupg|kube)(?:/|\z)}, /\.(?:pem|key|p12)\z/, %r{(?:\A|/)id_(?:rsa|ed25519|ecdsa)} ],
      destructive: [ %r{\A\.git(?:/|\z)} ]
    }.freeze

    Classification = Data.define(:operation, :effects, :risk) do
      def to_h = { operation:, effects:, risk:, confidence: :certain }
    end

    class << self
      def tool_names = TOOL_NAMES

      def covers?(tool_name) = TOOL_NAMES.include?(tool_name.to_s)

      def operation_for(tool_name) = "syrus.local_mode/#{tool_name}@v1"

      def descriptor_for(tool_name, required_roles: ROLES)
        tool = tool_name.to_s
        raise KeyError, "no Local Mode capability for #{tool}" unless covers?(tool)

        roles = Array(required_roles)
        CapabilityDescriptor.new(
          capability: CAPABILITY,
          operation: operation_for(tool),
          effects: %i[operator_host_access],
          risk: :high,
          requestable_roles: roles,
          defaults: roles.index_with { :ask },
          maximum_autonomy: :chat_session,
          authority_durations: %i[invocation chat_session],
          resource_scope: workspace_scope,
          classifier: ->(arguments) { classify(tool, arguments).to_h },
          fingerprint_normalizer: ->(arguments) { normalize_arguments(tool, arguments) },
          redactor: ->(arguments) { normalize_arguments(tool, arguments) }
        )
      end

      # The workspace a Local Mode daemon is attached to: the repository it
      # reported plus the normalized absolute root of the checkout it runs in.
      # Two checkouts of one repository are different workspaces, so authority
      # never carries from one to the other. A daemon that reports no root
      # (an older CLI) is scoped to its current connection, so authority cannot
      # outlive a reconnect.
      def workspace_scope
        ResourceScopeSchema.new(
          type: :local_workspace,
          normalize: lambda { |scope, context:|
            scope.to_h.transform_keys(&:to_s).slice("repository", "workspace_root")
              .transform_values { |value| value.to_s.strip }.reject { |_key, value| value.empty? }
          },
          label: lambda { |scope, context:|
            scope.empty? ? "Any Local Mode workspace" : "Workspace #{scope['workspace_root']} (#{scope['repository']})"
          },
          # An empty scope on a rule or lease means every workspace; an
          # invocation always carries the workspace it runs in.
          compare: lambda { |invocation, rule, context:|
            if rule.empty? then invocation.empty? ? :equal : :narrower
            elsif invocation == rule then :equal
            else :disjoint
            end
          }
        )
      end

      def resource_scope_for(chat_session)
        daemon = chat_session.local_daemon_session
        root = daemon&.daemon_workspace_root.presence || "connection:#{daemon&.connection_id.presence || "chat-session-#{chat_session.id}"}"
        { "repository" => daemon&.daemon_repo.to_s, "workspace_root" => root }
      end

      def classify(tool_name, arguments)
        arguments = arguments.to_h.transform_keys(&:to_s)
        effects = %i[operator_host_access]
        risk = :high
        if tool_name.to_s == "run_command"
          command = normalize_command(arguments["command"])
          effects << :network_read if command.match?(NETWORK_COMMAND)
          effects << :external_write if command.match?(PUSH_COMMAND)
          effects << :credential_use if command.match?(CREDENTIAL_COMMAND)
          effects << :destructive if command.match?(DESTRUCTIVE_COMMAND)
          effects << :privilege_change if command.match?(PRIVILEGED_COMMAND)
        else
          path = normalize_path(arguments["path"])
          if path.nil?
            effects << :destructive
          else
            PROTECTED_PATH_PATTERNS.each do |effect, patterns|
              effects << effect if patterns.any? { |pattern| path.match?(pattern) }
            end
          end
        end
        effects.uniq!
        risk = :critical if (effects & %i[destructive privilege_change credential_use external_write]).any?
        Classification.new(operation: operation_for(tool_name), effects:, risk:)
      end

      # True when the invocation carries no effect beyond plain host access, so
      # a lease issued from the descriptor can legitimately cover it.
      def session_eligible?(tool_name, arguments)
        classify(tool_name, arguments).effects == %i[operator_host_access]
      end

      # Exact, normalized arguments. The command is compared as typed apart
      # from line endings and surrounding whitespace; the path is made
      # root-relative and cleaned so +./a/../b+ and +b+ match; file content is
      # represented by its digest and size so it is exact without being stored.
      def normalize_arguments(tool_name, arguments)
        arguments = arguments.to_h.transform_keys(&:to_s)
        if tool_name.to_s == "run_command"
          { "command" => normalize_command(arguments["command"]) }
        else
          content = arguments["content"].to_s
          {
            "path" => normalize_path(arguments["path"]) || "outside-workspace:#{arguments['path']}",
            "content_sha256" => Digest::SHA256.hexdigest(content),
            "content_bytes" => content.bytesize
          }
        end
      end

      def normalize_command(command) = command.to_s.gsub("\r\n", "\n").strip

      # Root-relative cleaned path, or nil when the path is absolute or escapes
      # the workspace root.
      def normalize_path(path)
        candidate = Pathname.new(path.to_s.strip)
        return nil if candidate.to_s.empty? || candidate.absolute?

        clean = candidate.cleanpath
        return nil if clean.each_filename.first == ".."

        clean.to_s
      end
    end
  end
end
