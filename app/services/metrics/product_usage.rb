module Metrics
  # "Which features are actually used?", so that effort goes where people are
  # rather than where we guess they are.
  #
  # Two properties this is designed around, both easy to get wrong:
  #
  # **Absence is the signal.** The point of the exercise is finding features
  # nobody touches, and an unused counter and an uninstrumented one look
  # identical on a dashboard -- both are simply missing. So every feature is
  # declared at boot with an explicit zero (`preset`), and a flat line at 0 then
  # means "shipped, nobody uses it" rather than "we forgot to measure".
  #
  # **The feature list is a closed enum, not a free string.** Product analytics
  # is exactly where the temptation arrives to pass a user-supplied value as a
  # label, which is how a metrics system acquires unbounded cardinality.
  # `record` raises on an unknown key in development and test.
  #
  # Counted at the **web entry point** where a person asks for the thing, not
  # deep inside the worker that later performs it. Two reasons: the request is
  # where "someone used this" actually happens (a retried Run is not a second
  # use), and web is the only role currently scraped -- counters incremented in
  # a forked Solid Queue worker are not exported yet.
  module ProductUsage
    FEATURES = %i[
      direct_job_created
      epic_created
      chat_created
      chat_message_sent
      job_retried
      job_approved
    ].freeze

    class << self
      # A method rather than a bare block so it can be re-run after
      # Syrus::Metrics.reset! without reloading this file, which would warn
      # about redefined constants.
      def declare_metrics!
        Syrus::Metrics.declare do
          counter :feature_used_total, tags: %i[feature],
                  comment: "Feature invocations, counted at the request that asked for them"
        end
      end

      def record(feature)
        unless FEATURES.include?(feature)
          raise ArgumentError, "unknown feature #{feature.inspect}" if Rails.env.local?

          return
        end

        Syrus::Metrics.counter(:syrus_feature_used_total).increment(tags: { feature: feature })
      end

      # Publishes a zero for every feature so an unused one is visible as a zero
      # rather than as nothing at all. Called at boot; idempotent, and never
      # overwrites a count that already exists.
      def preset_all!
        counter = Syrus::Metrics.counter(:syrus_feature_used_total)
        FEATURES.each { |feature| counter.preset(tags: { feature: feature }) }
      end
    end

    declare_metrics!
  end
end
