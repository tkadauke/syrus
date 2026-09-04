module Syrus
  module Plugin
    # Marker interface for a rung-0 adjudicator (workflow-engine-v3).
    #
    # Providers expose:
    #
    #   .adjudicate(problem:, workflow: nil, step: nil, **context) => Adjudication
    #   .name                                                      => "short_identifier"
    #
    # Return `Adjudication.inconclusive` whenever the check does not apply or
    # cannot tell. That is not a formality: the ladder only works because a
    # cheap rung that declines lets a more expensive one take its turn, and an
    # adjudicator that guesses instead spends someone's attention on a wrong
    # answer.
    #
    # A language plugin that can tell "this grader was already failing" from
    # its own parsed output is the obvious contributor here.
    module Adjudicator
      def self.included(base) = base.extend(self)
    end
  end
end
