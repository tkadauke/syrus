module Mcp
  # Interactive chat tool parity: generic infrastructure.
  #
  # Every tool meaningful in an interactive chat is discoverable in every chat
  # context when its feature/plugin is enabled. Authorization comes from
  # canonical capability descriptors, operator identity, grants, resource
  # access, and runtime state -- never from the identity of the chat context.
  # Discovery parity and authorization policy stay separate: a risky,
  # destructive, admin, external-write, or credential-using tool is not an
  # exception merely because it is risky.
  #
  # A context-specific exception is allowed only when the operation is
  # semantically incoherent in that context. Every exception carries a stable
  # reason code, a human explanation, a responsible owner, and a regression
  # test reference. Bare exclusion booleans, anonymous name lists, and silent
  # role-only registrations are forbidden; `ReviewedException.build` refuses an
  # incomplete declaration and `ChatToolParity.report` flags unexplained
  # differences in either direction.
  #
  # Core knows only the built-in chat contexts (planner, coding, local) and the
  # exceptions for the tools it registers itself. Any other chat context is
  # contributed by a plugin through a *participant*: the plugin's chat tool set
  # answers `.chat_parity_participant` with an object responding to
  #
  #   context          Symbol naming the context (also its registry surface)
  #   enabled?         whether the contributing plugin is enabled
  #   reason_codes     { "code" => "meaning" } the participant owns
  #   exceptions       Array<Hash> reviewed exceptions over core-registered tools
  #   validate_provider!(tool_set) / validate_definition!(definition)   (optional)
  #   provider_available?(tool_set, chat_session, tier:)                (optional)
  #
  # A plugin tool set declares exceptions for the tools it contributes with
  # `.chat_parity_exceptions` (provider level) or `parity_exception:` on a
  # definition, and may own extra reason codes with `.chat_parity_reason_codes`.
  # With no participant installed, no context-specific policy is active.
  module ChatToolParity
    CORE_CONTEXTS = %i[planner coding local].freeze
    ALL = :all

    # Reason codes core itself owns; participants and tool sets add their own.
    CORE_REASON_CODES = {
      "workflow_run_bound_verdict" =>
        "Workflow verdict/callback tools bound to one specific reviewer or evaluator run.",
      "evaluator_run_bound" =>
        "Tools bound to the disposable scoped-event evaluator, which no interactive chat has.",
      "requires_coding_checkout" =>
        "Operation needs a Coding Mode checkout or runtime session that the other chat contexts do not have.",
      "requires_local_checkout" =>
        "Operation needs a Local Mode daemon workspace that the other chat contexts do not have."
    }.freeze

    REASON_CODE_FORMAT = /\A[a-z][a-z0-9_]*\z/

    # +absent_from+ names the contexts where the tool is legitimately absent
    # (or `:all`); +tools+ names the tools covered.
    ReviewedException = Data.define(:reason_code, :explanation, :owner, :test_ref, :absent_from, :tools) do
      def self.build(reason_code: nil, explanation: nil, owner: nil, test_ref: nil, absent_from: [], tools: [])
        attributes = { reason_code: reason_code.to_s, explanation: explanation.to_s, owner: owner.to_s,
                       test_ref: test_ref.to_s }
        missing = attributes.select { |_, value| value.strip.empty? }.keys
        raise ArgumentError, "chat tool parity exception is missing #{missing.join(', ')}" if missing.any?
        unless REASON_CODE_FORMAT.match?(attributes[:reason_code])
          raise ArgumentError, "chat tool parity reason code #{attributes[:reason_code].inspect} must be a snake_case code"
        end

        new(**attributes, absent_from: Array(absent_from).map(&:to_sym).freeze, tools: Array(tools).map(&:to_s).freeze)
      end

      # Accepts a ReviewedException or a plain hash, which is what a plugin
      # returns so it does not need a core constant.
      def self.coerce(value)
        return value if value.is_a?(self)
        raise ArgumentError, "chat tool parity exception must be a hash with metadata, got #{value.inspect}" unless value.respond_to?(:to_h)

        build(**value.to_h.symbolize_keys.slice(*members))
      end

      def absent_from?(context) = absent_from.include?(ALL) || absent_from.include?(context.to_sym)

      def covers?(tool_name) = tools.empty? || tools.include?(tool_name.to_s)

      def resolved_absent_from(contexts) = absent_from.include?(ALL) ? contexts : absent_from & contexts
    end

    WORKFLOW_VERDICT_TOOLS = %w[
      submit_summary submit_test_plan submit_report patch_workflow submit_adversarial_review
      submit_security_review submit_visual_review
    ].freeze

    CORE_EXCEPTIONS = [
      ReviewedException.build(
        reason_code: "workflow_run_bound_verdict",
        explanation: "Verdict/callback tools are bound to one reviewer or workflow run, not an interactive chat.",
        owner: "workflow-engine", test_ref: "spec/services/mcp/chat_tool_parity_spec.rb",
        absent_from: [ ALL ], tools: WORKFLOW_VERDICT_TOOLS
      )
    ].freeze

    # Exceptions derived from the entry's own role gate (dedicated chat
    # modes). The role requirement is the registered reason; no name list.
    ROLE_EXCEPTIONS = {
      AgentRole::CHAT_CODING => ReviewedException.build(
        reason_code: "requires_coding_checkout",
        explanation: "Needs a Coding Mode checkout or runtime session.",
        owner: "coding-mode", test_ref: "spec/services/mcp/chat_tool_parity_spec.rb",
        absent_from: [ ALL ]
      ),
      AgentRole::CHAT_LOCAL => ReviewedException.build(
        reason_code: "requires_local_checkout",
        explanation: "Needs a Local Mode daemon workspace.",
        owner: "local-mode", test_ref: "spec/services/mcp/chat_tool_parity_spec.rb",
        absent_from: [ ALL ]
      ),
      AgentRole::CHAT_EVALUATOR => ReviewedException.build(
        reason_code: "evaluator_run_bound",
        explanation: "Bound to the disposable scoped-event evaluator.",
        owner: "chat", test_ref: "spec/services/mcp/chat_tool_parity_spec.rb",
        absent_from: [ ALL ]
      )
    }.freeze

    ROLE_CONTEXTS = {
      AgentRole::CHAT_PLANNER => :planner,
      AgentRole::CHAT_CODING => :coding,
      AgentRole::CHAT_LOCAL => :local,
      AgentRole::CHAT_EVALUATOR => nil
    }.freeze

    class << self
      # Chat tool sets of every installed plugin, whether or not the operator
      # has enabled it: parity and the generated docs must not depend on the
      # instance's enablement state.
      def installed_chat_tool_sets
        Syrus::PluginRegistry.all_plugins.flat_map do |manifest|
          Array(Syrus::Plugin::Toolkit.chat_tool_set_for(manifest)).map do |tool_set|
            tool_set.is_a?(String) ? Object.const_get(tool_set) : tool_set
          end
        end.uniq
      end

      # Participants contributed by installed (or only enabled) plugins. The
      # installed set is static for a process, so the default lookup is memoized.
      def participants(enabled_only: false, tool_sets: nil)
        found = if tool_sets
          participants_of(tool_sets)
        else
          @installed_participants ||= participants_of(installed_chat_tool_sets)
        end
        enabled_only ? found.select(&:enabled?) : found
      end

      def reset!
        @installed_participants = nil
      end

      def participants_of(tool_sets)
        tool_sets.filter_map do |tool_set|
          tool_set.chat_parity_participant if tool_set.respond_to?(:chat_parity_participant)
        end.uniq
      end

      def participant_for(context, enabled_only: false)
        participants(enabled_only: enabled_only).find { |participant| participant.context == context.to_sym }
      end

      def contexts(participants: self.participants)
        CORE_CONTEXTS + participants.map(&:context)
      end

      def reason_codes(participants: self.participants)
        participants.map(&:reason_codes).reduce(CORE_REASON_CODES) { |all, codes| all.merge(codes) }
      end

      # Core-owned exceptions plus those participants declare over core tools.
      def core_exceptions(participants: self.participants)
        CORE_EXCEPTIONS + participants.flat_map { |participant| participant.exceptions.map { |value| ReviewedException.coerce(value) } }
      end

      def exceptions(participants: self.participants)
        core_exceptions(participants:) + ROLE_EXCEPTIONS.values
      end

      # Whether a core-registered chat entry is discoverable in +context+.
      def core_entry_in_context?(entry, context, participants: self.participants)
        !declared_absences(entry.tool_name, entry, participants:).include?(context.to_sym)
      end

      # Contexts in which a chat registry entry is discoverable by its role gate.
      # A participant that declares its +agent_role+ shares entries gated on it.
      def chat_contexts_for(entry, participants: self.participants)
        roles = entry.required_roles
        return CORE_CONTEXTS if roles.empty?

        core = ROLE_CONTEXTS.filter_map { |role, context| context if context && roles.include?(role) }
        core + participants.filter_map do |participant|
          participant.context if participant.respond_to?(:agent_role) && roles.include?(participant.agent_role)
        end
      end

      # Contexts where a tool is legitimately absent, per reviewed exceptions.
      def declared_absences(tool_name, entry, participants: self.participants)
        all = contexts(participants:)
        by_name = core_exceptions(participants:).select { |exception| exception.tools.include?(tool_name) }
        absent = by_name.flat_map { |exception| exception.resolved_absent_from(all) }
        role = entry && ROLE_EXCEPTIONS.keys.find { |candidate| entry.required_roles.include?(candidate) }
        absent += all - chat_contexts_for(entry, participants:) if role
        absent.uniq
      end

      # Resolved core catalogs per context, from the registry.
      def catalogs(participants: self.participants)
        chat = McpToolRegistry.entries(surface: :chat).group_by(&:tool_name)
        by_context = contexts(participants:).index_with { Set.new }
        chat.each do |name, entries|
          entries.flat_map { |entry| chat_contexts_for(entry, participants:) }.each { |context| by_context[context] << name if by_context.key?(context) }
        end
        participants.each do |participant|
          by_context[participant.context] = McpToolRegistry.entries(surface: participant.context).map(&:tool_name).to_set
        end
        by_context
      end

      # --- plugin tool sets ------------------------------------------------

      # Provider-level exceptions. An exception that lists no tools covers every
      # tool of the provider; +expand+ resolves that to the provider's tool names.
      def provider_exceptions(provider, expand: false)
        return [] unless provider.respond_to?(:chat_parity_exceptions)

        names = expand ? Array(provider.tool_definitions(tier: nil)).map { |d| (d[:name] || d["name"]).to_s } : []
        Array(provider.chat_parity_exceptions).map do |value|
          exception = ReviewedException.coerce(value)
          expand && exception.tools.empty? ? exception.with(tools: names.freeze) : exception
        rescue ArgumentError => e
          raise ArgumentError, "#{provider}: #{e.message}"
        end
      end

      def definition_exception(definition)
        exception = definition[:parity_exception] || definition["parity_exception"]
        return nil unless exception

        ReviewedException.coerce({ tools: [ definition[:name] || definition["name"] ] }.merge(exception.to_h.symbolize_keys))
      end

      def plugin_exceptions_by_provider(providers = installed_chat_tool_sets)
        providers.to_h do |provider|
          definitions = Array(provider.tool_definitions(tier: nil))
          [ provider, provider_exceptions(provider, expand: true) + definitions.filter_map { |definition| definition_exception(definition) } ]
        end
      end

      # Every reviewed exception installed plugins declare.
      def plugin_exceptions(providers = installed_chat_tool_sets)
        plugin_exceptions_by_provider(providers).values.flatten
      end

      # Whether a reviewed exception hides the whole provider (one that lists no
      # tools) from +context+. Participants reject APIs they no longer support.
      def provider_hidden?(provider, context, participants: self.participants)
        participants.each { |participant| participant.validate_provider!(provider) if participant.respond_to?(:validate_provider!) }
        provider_exceptions(provider).any? { |exception| exception.tools.empty? && exception.absent_from?(context) }
      end

      # Whether a plugin provider is offered in +context+: not hidden wholesale,
      # and at least one of its tools is not hidden there by an exception.
      def plugin_provider_in_context?(provider, context, participants: self.participants)
        return false if provider_hidden?(provider, context, participants:)

        definitions = Array(provider.tool_definitions(tier: nil))
        definitions.empty? || definitions.any? { |definition| !plugin_tool_hidden?(provider, definition, context) }
      end

      # Whether a reviewed exception of +provider+ or +definition+ hides the tool.
      def plugin_tool_hidden?(provider, definition, context)
        name = (definition[:name] || definition["name"]).to_s
        exceptions = provider_exceptions(provider) + [ definition_exception(definition) ].compact
        exceptions.any? { |exception| exception.absent_from?(context) && exception.covers?(name) }
      end

      # Whether +definition+ is offered in +context+. +user+ gates `admin_only`
      # definitions exactly as for ordinary chats. Pass +provider+ to honour its
      # provider-level exceptions as well as the definition's own.
      def plugin_definition_in_context?(definition, context, user: nil, provider: nil, participants: self.participants)
        participants.each { |participant| participant.validate_definition!(definition) if participant.respond_to?(:validate_definition!) }
        exception = definition_exception(definition)
        return false if exception&.absent_from?(context)
        return false if provider && plugin_tool_hidden?(provider, definition, context)
        return true unless definition[:admin_only] || definition["admin_only"]

        user.respond_to?(:admin?) && user.admin?
      end

      # Whether +tool_set+ is available to +chat_session+ in the context a
      # participant owns, delegating to the participant when it has an opinion.
      def plugin_provider_available?(tool_set, context, chat_session, tier:)
        participant = participant_for(context, enabled_only: true)
        return tool_set.available_for?(chat_session, tier: tier) unless participant
        return false if provider_hidden?(tool_set, context)
        return participant.provider_available?(tool_set, chat_session, tier: tier) if participant.respond_to?(:provider_available?)

        tool_set.available_for?(chat_session, tier: tier)
      end

      # Whether an extension context filters plugin definitions at all.
      def extension_context?(context)
        context && participants(enabled_only: true).any? { |participant| participant.context == context.to_sym }
      end

      # Installed plugin chat tool sets, resolved per context. +user+ resolves
      # admin-gated definitions as an admin owner would see them at call time.
      def plugin_catalogs(providers = installed_chat_tool_sets, participants: nil)
        parts = participants || self.participants(tool_sets: installed_chat_tool_sets | providers)
        admin = Struct.new(:admin?).new(true)
        providers.to_h do |provider|
          definitions = Array(provider.tool_definitions(tier: nil))
          by_context = contexts(participants: parts).index_with do |context|
            visible = plugin_provider_in_context?(provider, context, participants: parts)
            names = visible ? definitions.select { |d| plugin_definition_in_context?(d, context, user: admin, provider:, participants: parts) } : []
            names.map { |d| (d[:name] || d["name"]).to_s }.to_set
          end
          [ provider, by_context ]
        end
      end

      # Plugin differences across contexts that no declared exception of the
      # same provider covers.
      def plugin_report(providers = installed_chat_tool_sets, participants: nil)
        parts = participants || self.participants(tool_sets: installed_chat_tool_sets | providers)
        all = contexts(participants: parts)
        by_provider = plugin_exceptions_by_provider(providers)
        valid_codes = reason_codes(participants: parts)
        plugin_catalogs(providers, participants: parts).flat_map do |provider, by_context|
          exceptions = by_provider.fetch(provider)
          own_codes = provider.respond_to?(:chat_parity_reason_codes) ? provider.chat_parity_reason_codes : {}
          problems = exceptions.filter_map do |exception|
            unless valid_codes.merge(own_codes).key?(exception.reason_code)
              "#{provider}: exception uses undeclared reason code #{exception.reason_code}"
            end
          end
          problems += exceptions.flat_map { |e| e.absent_from - all - [ ALL ] }.uniq.map do |context|
            "#{provider}: exception names unknown context #{context}"
          end
          names = by_context.values.reduce(:|)
          declared = Array(provider.tool_definitions(tier: nil)).map { |d| (d[:name] || d["name"]).to_s }
          (names | declared.to_set).sort.each do |name|
            allowed = exceptions.select { |exception| exception.tools.include?(name) }.flat_map { |e| e.resolved_absent_from(all) }.uniq
            actual = all.reject { |context| by_context[context].include?(name) }
            unexplained = actual - allowed
            stale = allowed - actual
            problems << "#{provider}##{name}: unexplained absence from #{unexplained.join(', ')}" if unexplained.any?
            problems << "#{provider}##{name}: exception no longer applies to #{stale.join(', ')}" if stale.any?
          end
          problems
        end
      end

      # Differences not covered by a reviewed exception, in both directions:
      # a tool missing where it should be shared, an exception that no longer
      # matches reality, and a context-only tool nothing justifies.
      def report(participants: self.participants, providers: installed_chat_tool_sets)
        by_context = catalogs(participants:)
        all = contexts(participants:)
        entries = McpToolRegistry.entries(surface: :chat).group_by(&:tool_name)
        names = by_context.values.reduce(:|)
        problems = []

        names.sort.each do |name|
          entry = entries[name]&.first
          allowed_absent = declared_absences(name, entry, participants:)
          actual_absent = all.reject { |context| by_context[context].include?(name) }
          unexplained = actual_absent - allowed_absent
          stale = allowed_absent - actual_absent
          problems << "#{name}: unexplained absence from #{unexplained.join(', ')}" if unexplained.any?
          problems << "#{name}: exception no longer applies to #{stale.join(', ')}" if stale.any?
        end

        codes = reason_codes(participants:)
        core_exceptions(participants:).each do |exception|
          problems << "#{exception.tools.first || 'exception'}: unknown reason code #{exception.reason_code}" unless codes.key?(exception.reason_code)
        end
        registered = McpToolRegistry.entries.map(&:tool_name).to_set
        # Run-bound verdict tools live on the workflow surface, which may be
        # contributed by a plugin this registry does not load.
        core_exceptions(participants:).reject { |exception| exception.absent_from.include?(ALL) }.flat_map(&:tools).uniq.each do |name|
          problems << "#{name}: exception names a tool that is not registered" unless registered.include?(name)
        end
        problems + plugin_report(providers, participants:)
      end
    end
  end
end
