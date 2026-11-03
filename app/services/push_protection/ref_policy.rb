module PushProtection
  # Who may rewrite the rejected ref. Mutable Job-owned branches are repaired in
  # place; synthesized or shared refs (merge-train / integration / promotion /
  # hotfix history) are quarantined and routed back to the originating Job.
  class RefPolicy
    SHARED_PATTERN = %r{\Arefs/heads/(?:.*(?:merge-train|integration|promotion|hotfix-sync|speculative)).*}i

    def self.for(ref:, job: nil)
      normalized = ref.to_s.start_with?("refs/") ? ref.to_s : "refs/heads/#{ref}"
      return SharedRef.new if normalized.match?(SHARED_PATTERN)

      # The Job's branch, its checkpoints, handoff branches and source
      # snapshots all carry only this Job's own commits.
      MutableJobRef.new
    end

    class MutableJobRef < RefPolicy
      def repairable? = true
      def outcome = :repair
    end

    class SharedRef < RefPolicy
      def repairable? = false
      def outcome = :quarantine
    end
  end
end
