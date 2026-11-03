module Permissions
  # Capability-specific fresh-authentication requirement.
  #
  # A descriptor may declare +fresh_authentication_window+: the approver must
  # have authenticated within that window for the capability to proceed without
  # a prompt. Like the execution ceilings this can only lower a decision
  # (allow -> ask); it never raises one and never turns a deny into anything
  # else. +authenticated_at+ is supplied by the caller (a session, an approval
  # surface); an unknown time is treated as not fresh.
  class FreshAuthentication
    RANK = PolicyEvaluator::POLICY_RANK

    Applied = Data.define(:source, :policy, :reason, :window) do
      def to_h = { source:, policy:, reason:, window: }
    end

    def self.satisfied?(descriptor, authenticated_at:, now: Time.current)
      window = descriptor.fresh_authentication_window
      return true if window.nil?
      return false if authenticated_at.nil?

      authenticated_at >= now - window
    end

    # Returns [final_policy, Applied or nil].
    def self.apply(policy, descriptor:, authenticated_at:, now: Time.current)
      return [ policy, nil ] if satisfied?(descriptor, authenticated_at:, now:)
      return [ policy, nil ] if RANK.fetch(policy) <= RANK.fetch(:ask)

      [ :ask, Applied.new(source: :capability, policy: :ask, reason: :fresh_authentication_required,
        window: descriptor.fresh_authentication_window) ]
    end
  end
end
