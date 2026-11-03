require "digest"

module Permissions
  # Stable capability contracts for effects that never pass through ordinary MCP
  # tool dispatch: processes Syrus starts on a worker host or in a container
  # (+Execution::Request+), and actions an agent provider performs natively
  # (its own shell, file, and web tools).
  #
  # All three operations live under +syrus.execution@v1+:
  #
  # - +host_process+: a command run directly on the worker.
  # - +container_process+: a command run inside a confined execution backend.
  # - +provider_native_action+: a provider-native tool call.
  #
  # The classifier only ever adds effects, from the command line, the network
  # profile, the environment, and writable mounts. The defaults keep today's
  # behavior for plain confined work (+allow+) and make anything that uses the
  # network beyond the profile, a credential, a privilege change, or a
  # destructive operation +ask+ (see +ExecutionAuthorization+). Confinement and
  # provider ceilings are applied after policy evaluation and can only narrow
  # the result.
  class ExecutionActions
    CAPABILITY = "syrus.execution@v1".freeze
    LOCATIONS = %i[host container provider_native].freeze
    OPERATIONS = {
      host: "host_process",
      container: "container_process",
      provider_native: "provider_native_action"
    }.freeze

    ROLES = (AgentRole::WORKFLOW_ROLES + AgentRole::CHAT_ROLES + [ AgentRole::COWORKER, AgentRole::AGENT_INSIGHT, AgentRole::INFRASTRUCTURE_MAIN_REPAIR ]).freeze

    # Effects that should never be silently allowed by the descriptor default.
    SENSITIVE_EFFECTS = %i[credential_use privilege_change destructive external_write irreversible].freeze

    CREDENTIAL_ENV = /(?:TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_KEY|CREDENTIAL|ACCESS_KEY)/i

    Subject = Data.define(:location, :command, :network, :env_keys, :writable_paths, :provider, :tool, :container_backend)

    class << self
      def operation_names = OPERATIONS.values

      # Execution has no MCP tool to carry its descriptors into the catalog, so
      # they are listed here for rule management and the permissions hub.
      def descriptors = LOCATIONS.map { |location| descriptor_for(location) }

      def operation_for(location) = "syrus.execution/#{OPERATIONS.fetch(location.to_sym)}@v1"

      def descriptor_for(location, required_roles: ROLES)
        location = location.to_sym
        raise KeyError, "no execution capability for #{location}" unless LOCATIONS.include?(location)

        roles = Array(required_roles)
        CapabilityDescriptor.new(
          capability: CAPABILITY,
          operation: operation_for(location),
          effects: location == :host ? %i[operator_host_access] : %i[isolated_execution],
          risk: location == :host ? :high : :medium,
          requestable_roles: roles,
          defaults: roles.index_with { :allow },
          maximum_autonomy: :job,
          authority_durations: %i[invocation chat_session job],
          resource_scope: { type: :none },
          classifier: ->(arguments) { classify(location, arguments).to_h },
          fingerprint_normalizer: ->(arguments) { normalize_arguments(location, arguments) },
          redactor: ->(arguments) { redact_arguments(location, arguments) },
          budget_dimensions: %i[compute_time]
        )
      end

      # Builds the neutral subject from an Execution::Request. Environment
      # names are deliberately not carried: nearly every Syrus-launched process
      # receives injected token variables, so they say nothing about intent.
      # Callers that know a credential is deliberately exposed can pass
      # +env_keys+ on a provider-native subject instead.
      def subject_for_request(request, location: nil, writable_paths: [])
        location ||= confined_request?(request) ? :container : :host
        Subject.new(
          location: location.to_sym,
          command: Array(request.command).map(&:to_s),
          network: request.network.to_s,
          env_keys: [],
          writable_paths: Array(writable_paths).map(&:to_s),
          provider: nil, tool: nil,
          container_backend: confined_request?(request) ? :required : nil
        )
      end

      def subject_for_provider_action(provider:, tool:, command: nil, network: nil)
        Subject.new(
          location: :provider_native, command: Array(command).map(&:to_s), network: network.to_s,
          env_keys: [], writable_paths: [], provider: provider.to_s, tool: tool.to_s, container_backend: nil
        )
      end

      def arguments_for(subject)
        subject.to_h.transform_keys(&:to_s)
      end

      def classify(location, arguments)
        arguments = arguments.to_h.transform_keys(&:to_s)
        location = location.to_sym
        effects = location == :host ? %i[operator_host_access] : %i[isolated_execution]
        command = Array(arguments["command"]).map(&:to_s).join(" ")
        command = LocalModeActions.normalize_command(command)

        effects << :network_read if network_open?(arguments["network"])
        effects.concat(LocalModeActions.command_effects(command))
        effects << :credential_use if credential_env?(arguments["env_keys"])
        effects << :isolated_workspace_write if Array(arguments["writable_paths"]).any?
        effects.uniq!

        risk = if (effects & %i[destructive privilege_change credential_use external_write]).any? then :critical
        elsif location == :host then :high
        else :medium
        end
        { operation: operation_for(location), effects:, risk:, confidence: :certain }
      end

      # Exact, key-sorted arguments. Environment values are never present.
      def normalize_arguments(location, arguments)
        arguments = arguments.to_h.transform_keys(&:to_s)
        {
          "location" => location.to_s,
          "command" => Array(arguments["command"]).map(&:to_s),
          "network" => arguments["network"].to_s,
          "env_keys" => Array(arguments["env_keys"]).map(&:to_s).sort,
          "writable_paths" => Array(arguments["writable_paths"]).map(&:to_s).sort,
          "provider" => arguments["provider"].to_s,
          "tool" => arguments["tool"].to_s
        }
      end

      # Commands can embed secrets, so history keeps only a digest and the
      # leading executable.
      def redact_arguments(location, arguments)
        normalized = normalize_arguments(location, arguments)
        command = normalized["command"]
        normalized.merge(
          "command" => nil,
          "executable" => File.basename(command.first.to_s),
          "command_sha256" => Digest::SHA256.hexdigest(command.join("\0"))
        ).compact
      end

      # True when the profile permits egress at all. The grader profile is
      # loopback-only, so it never counts as network use by itself.
      def network_open?(profile)
        profile.to_s.present? && ProcessRunner::NetworkProfile::PROFILES.key?(profile.to_s) && profile.to_s != "grader"
      end

      def credential_env?(keys) = Array(keys).any? { |key| key.to_s.match?(CREDENTIAL_ENV) }

      private

      def confined_request?(request)
        request.workload_policy&.fail_closed? == true
      end
    end
  end
end
