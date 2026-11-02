module WorkspaceReuseOutcomes
  class Summary
    def self.call(since:, until_time: Time.current, repository: nil)
      scope = WorkspaceReuseOutcome.where(occurred_at: since..until_time)
      scope = scope.where(repository: repository) if repository
      counts = scope.group(:repository_id, :prepare_fingerprint, :backend, :kind, :outcome).count
      counts.group_by { |keys, _count| keys.first(4) }.map do |keys, entries|
        repository_id, prepare_fingerprint, backend, kind = keys
        outcomes = entries.to_h { |outcome_keys, count| [ outcome_keys.last, count ] }
        total = outcomes.values.sum
        reused = outcomes.fetch("reused_from_archive", 0)
        reuse_opportunities = reused + outcomes.fetch("rebuilt", 0)
        {
          repository_id: repository_id,
          prepare_fingerprint: prepare_fingerprint,
          backend: backend,
          kind: kind,
          outcomes: outcomes,
          total_count: total,
          reuse_rate: kind == "prepare" && reuse_opportunities.positive? ? reused.fdiv(reuse_opportunities) : nil
        }
      end
    end
  end
end
