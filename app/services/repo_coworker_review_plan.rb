class RepoCoworkerReviewPlan
  Result = Data.define(:enabled, :rounds, :source, :note, :criteria, :required) do
    def enabled? = enabled && rounds.to_i.positive?
  end

  def self.for_job(job)
    from_syrus_yml(RepoDefaultBranchSyrusYml.for_job(job))
  end

  def self.from_syrus_yml(loaded)
    return disabled(source: loaded.source, note: loaded.note) unless loaded.config

    review = loaded.config.coworker_review
    return disabled(source: loaded.source, note: "no coworker_review configured") unless review
    unless loaded.config.plugin_configurations.contribution("coworkers.review")
      return disabled(source: loaded.source, note: "coworker_review provider is unavailable")
    end

    Result.new(enabled: review.enabled, rounds: review.rounds, source: loaded.source, note: nil,
               criteria: review.criteria, required: review.required)
  end

  def self.disabled(source:, note:)
    Result.new(enabled: false, rounds: 0, source: source, note: note, criteria: [], required: false)
  end
end
