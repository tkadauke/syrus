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
  #
  # `authorized:` is the plan's "an adjudication never applies itself" guardrail
  # made concrete: a call site names the adjudicators whose verdict it will act
  # on. An unauthorized adjudicator still runs and its verdict is still
  # returned for the record, but it comes back marked so the caller does not
  # act on it. `:all` pre-authorizes every adjudicator, for a site where that
  # is the policy.
  def self.call(problem:, authorized: [], **context)
    declined = []

    all.each do |adjudicator|
      verdict = adjudicate_one(adjudicator, problem: problem, **context)
      next declined << adjudicator.name unless verdict.decided?

      return verdict if authorized_for?(authorized, adjudicator)

      return Adjudication.inconclusive(
        adjudicator: adjudicator.name,
        reason: "verdict_not_authorized_here",
        evidence: { withheld_verdict: verdict.verdict.to_s, withheld_reason: verdict.reason }
      )
    end

    Adjudication.inconclusive(reason: "no_adjudicator_decided", evidence: { consulted: declined })
  end

  def self.authorized_for?(authorized, adjudicator)
    return true if authorized == :all

    Array(authorized).map(&:to_s).include?(adjudicator.name.to_s)
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
