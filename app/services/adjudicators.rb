# Rung 0 of the attention ladder (workflow-engine-v3): free, deterministic
# adjudication, tried before anything is spent on a repair or a turn.
#
# Each adjudicator answers `(problem, context) -> Adjudication`. They are
# consulted in order and the first one to decide wins; an adjudicator that
# cannot tell returns `inconclusive` and the next gets its turn. When none
# decides, the caller proceeds exactly as it did before rung 0 existed.
#
# The point of naming the interface is that the three deterministic checks
# Syrus already had -- inherited grader failures, landing validation reuse,
# timeout detection -- each answered in their own shape, so none composed and
# none could be tried ahead of an agent turn.
module Adjudicators
  BUILT_INS = [
    Adjudicators::InheritedGraderFailure,
    Adjudicators::ValidatedLanding
  ].freeze

  # Returns the first decided verdict, or an inconclusive one carrying every
  # adjudicator that declined -- the ladder needs to know it genuinely asked.
  def self.call(problem:, **context)
    declined = []

    all.each do |adjudicator|
      verdict = adjudicate_one(adjudicator, problem: problem, **context)
      return verdict if verdict.decided?

      declined << adjudicator.name
    end

    Adjudication.inconclusive(reason: "no_adjudicator_decided", evidence: { consulted: declined })
  end

  def self.all
    BUILT_INS + Syrus::PluginRegistry.providers_for(:adjudicator)
  end

  # An adjudicator that raises is declining, loudly. Rung 0 runs on the failure
  # path, and a broken cheap check must not stop the expensive rungs from
  # getting their turn.
  def self.adjudicate_one(adjudicator, problem:, **context)
    adjudicator.adjudicate(problem: problem, **context)
  rescue StandardError => e
    Rails.logger.warn("[Adjudicators] #{adjudicator.name} raised #{e.class}: #{e.message}")
    Adjudication.inconclusive(adjudicator: adjudicator.name, reason: "adjudicator_error")
  end
end
