class RepoSecurityReviewPlan
  Result = Data.define(:rounds, :source, :note, :criteria) do
    def enabled? = rounds.to_i.positive?
  end

  def self.for_job(job)
    from_syrus_yml(RepoDefaultBranchSyrusYml.for_job(job))
  end

  def self.from_syrus_yml(loaded)
    return disabled(source: loaded.source, note: loaded.note) unless loaded.config
    review = loaded.config.security_review
    return disabled(source: loaded.source, note: "no security_review configured") unless review

    Result.new(rounds: review.rounds, source: loaded.source, note: nil, criteria: review.criteria)
  end

  def self.disabled(source:, note:)
    Result.new(rounds: 0, source: source, note: note, criteria: [])
  end
end
