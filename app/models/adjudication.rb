# A verdict on whether a Problem should stand (workflow-engine-v3 rung 0).
#
# Syrus already adjudicates deterministically in three places -- `.syrus.yml`'s
# `grade.failures: allow_inherited` via MainBranchFailureClassifier, the
# LandingValidationCache's reuse decision, and timeout detection -- but each
# answers in its own shape, so none of them compose and none can be tried
# before spending an agent turn.
#
# The shared answer is one of three:
#
#   :uphold       -- the problem is real; remediate it
#   :dismiss      -- the problem is not this workflow's fault; carry on
#   :inconclusive -- no opinion, ask the next rung
#
# `inconclusive` is the important one. An adjudicator that cannot tell must say
# so rather than guessing, because the whole point of the ladder is that a
# cheap rung declines and a more expensive one gets its turn.
class Adjudication
  VERDICTS = %i[uphold dismiss inconclusive].freeze

  attr_reader :verdict, :reason, :evidence, :adjudicator

  def self.uphold(reason:, adjudicator: nil, evidence: {})
    new(:uphold, reason: reason, adjudicator: adjudicator, evidence: evidence)
  end

  def self.dismiss(reason:, adjudicator: nil, evidence: {})
    new(:dismiss, reason: reason, adjudicator: adjudicator, evidence: evidence)
  end

  def self.inconclusive(reason: nil, adjudicator: nil, evidence: {})
    new(:inconclusive, reason: reason, adjudicator: adjudicator, evidence: evidence)
  end

  def initialize(verdict, reason: nil, adjudicator: nil, evidence: {})
    @verdict = verdict.to_sym
    raise ArgumentError, "unknown adjudication verdict=#{verdict.inspect}" unless VERDICTS.include?(@verdict)

    @reason = reason
    @adjudicator = adjudicator
    @evidence = evidence.to_h.freeze
    freeze
  end

  def uphold? = verdict == :uphold
  def dismiss? = verdict == :dismiss
  def inconclusive? = verdict == :inconclusive

  # Whether this verdict settles the question, or the ladder should keep going.
  def decided? = !inconclusive?

  def to_h
    { verdict: verdict.to_s, reason: reason, adjudicator: adjudicator.to_s.presence, evidence: evidence }.compact
  end

  def inspect = "#<Adjudication #{verdict}#{reason ? " #{reason}" : ""}>"
end
