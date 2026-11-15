module Permissions
  # The single rule deciding whether a coworker tool may default to +allow+.
  #
  # A default of +allow+ is permitted only when every classified invocation is
  # low risk and confined to local reads, isolated workspace writes, or an
  # +internal_write+ that the descriptor explicitly declares as one of the
  # benign internal kinds (bounded read-only context binding, owner-directed
  # interaction, self-authority reduction, or a non-executing operator-confirmed
  # draft). Everything else defaults to +ask+ (or +deny+ when a descriptor says
  # so). Explicit user rules, denies, and ceilings are layered on top of this
  # default by PolicyEvaluator and are never widened by it.
  class CoworkerDefaultPolicy
    ROLES = [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ].freeze
    SAFE_EFFECTS = %i[local_read isolated_workspace_write].freeze

    # Reason codes are audit data (rake/JSON report), not end-user copy.
    BENIGN_REASONS = {
      context_binding: "bounded, reversible, read-only repository context management",
      owner_interaction: "interaction directed at the owner of this chat",
      authority_reduction: "reduces the coworker's own authority",
      draft_proposal: "creates only a non-executing draft that an operator must confirm"
    }.freeze
    UNSAFE_EFFECT_REASONS = {
      confidential_read: "reads confidential, cross-chat, or operational data",
      network_read: "network read not proven public and benign",
      credential_use: "uses credentials",
      communication: "communicates with third parties or other coworkers",
      persistent_autonomy: "creates schedules or persistent autonomy",
      external_write: "external effect with meaningful consequences",
      internal_write: "internal effect with meaningful consequences",
      financial: "financial effect",
      privilege_change: "changes privileges",
      operational: "operational effect",
      destructive: "destructive action",
      irreversible: "irreversible action",
      isolated_execution: "executes code",
      operator_host_access: "touches the operator host"
    }.freeze

    Verdict = Data.define(:policy, :reason, :auto_allowable)

    class << self
      # Whether the classified effects and risk are provably benign. +benign_internal+
      # comes from the descriptor so a dynamic classifier cannot invent it.
      def auto_allowable?(effects:, risk:, benign_internal: nil)
        return false unless risk.to_sym == :low

        effects = Array(effects).map(&:to_sym)
        unsafe = effects - SAFE_EFFECTS
        unsafe -= [ :internal_write ] if benign_internal
        unsafe.empty?
      end

      def descriptor_auto_allowable?(descriptor)
        auto_allowable?(effects: descriptor.effects, risk: descriptor.risk, benign_internal: descriptor.benign_internal)
      end

      # The default a coworker role gets for a descriptor, with the reason.
      def verdict(descriptor, role: ROLES.first)
        unless descriptor.requestable_roles.include?(role.to_s)
          return Verdict.new(policy: :deny, auto_allowable: false,
            reason: "not requestable by coworker roles by default (#{unsafe_summary(descriptor)}); needs an explicit grant")
        end

        policy = descriptor.defaults.fetch(role.to_s, :deny)
        allowable = descriptor_auto_allowable?(descriptor)
        Verdict.new(policy:, reason: reason(descriptor, policy, allowable), auto_allowable: allowable)
      end

      # Descriptor-level contradiction: an `allow` default that the effects do not justify.
      def requestable?(descriptor, role: ROLES.first) = descriptor.requestable_roles.include?(role.to_s)

      def violations(descriptor)
        ROLES.filter_map do |role|
          next unless descriptor.requestable_roles.include?(role)
          next unless descriptor.defaults.fetch(role, :deny) == :allow
          next if descriptor_auto_allowable?(descriptor)

          "#{descriptor.operation} defaults to allow for #{role} but is not fully benign (#{unsafe_summary(descriptor)})"
        end
      end

      def validate!(descriptor)
        problems = violations(descriptor)
        raise ArgumentError, problems.join("; ") if problems.any?

        descriptor
      end

      # Runtime guard for dynamic classification: a role default of allow only
      # holds when this invocation's own classification is benign too.
      def invocation_allowed?(descriptor, classification)
        auto_allowable?(effects: classification.effects, risk: classification.risk, benign_internal: descriptor.benign_internal) &&
          !classification.fallback?
      end

      def grant_policy_for(policies)
        policies = Array(policies).map(&:to_sym)
        return "off" if policies.empty? || policies.include?(:deny)

        policies.all?(:allow) ? "auto" : "confirm"
      end

      private

      def unsafe_summary(descriptor)
        parts = (descriptor.effects - SAFE_EFFECTS).map(&:to_s)
        parts << "risk #{descriptor.risk}" unless descriptor.risk == :low
        parts.join(", ")
      end

      def reason(descriptor, policy, allowable)
        case policy
        when :allow
          return BENIGN_REASONS.fetch(descriptor.benign_internal) if descriptor.benign_internal

          "only #{descriptor.effects.join('/')} at #{descriptor.risk} risk"
        else
          blocking = (descriptor.effects - SAFE_EFFECTS).first
          blocking = nil if blocking == :internal_write && descriptor.benign_internal
          return UNSAFE_EFFECT_REASONS.fetch(blocking) if blocking
          return "#{descriptor.risk} risk" unless descriptor.risk == :low

          allowable ? "explicit #{policy} default stricter than classification" : "not provably benign"
        end
      end
    end
  end
end
