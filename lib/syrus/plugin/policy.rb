# frozen_string_literal: true

module Syrus
  module Plugin
    # Authorization-adjacent restrictions applied to Job and repository
    # discovery. Unlike the usual decline-on-error rule, the composition here is
    # explicit and fails closed: every restriction applies, and a provider that
    # errors, times out, trips its circuit breaker, or returns an invalid value
    # contributes FAIL_CLOSED instead of silently dropping out. Callers must
    # treat FAIL_CLOSED as "show nothing" so an unavailable restriction can
    # never widen visibility.
    module Policy
      # Marker returned in place of a failed provider's restriction.
      FAIL_CLOSED = Module.new do
        def self.inspect = "Syrus::Plugin::Policy::FAIL_CLOSED"
        def self.name = "Syrus::Plugin::Policy::FAIL_CLOSED"
      end

      CAPABILITY_FOR_LEGACY = {
        job_visibility_restriction: :job_visibility_restrictions,
        repository_filter: :repository_filters
      }.freeze

      def self.provider(key:, display_name:, **contributions) =
        ContributionProvider.build(key:, display_name:, **contributions)

      # Every restriction that applies, with FAIL_CLOSED standing in for any
      # provider that could not be evaluated.
      def self.restrictions(capability)
        Dispatch.call(:policy, capability, Context::PolicyContext.new).flatten.compact
      end

      # Applies every repository filter to +scope+. A filter that cannot be
      # evaluated, or that raises while applying, yields an empty scope.
      def self.filter_repositories(scope, user:)
        restrictions(:repository_filters).reduce(scope) do |visible, filter|
          next visible.none if filter.equal?(FAIL_CLOSED)

          filter.apply(scope: visible, user:)
        rescue StandardError => error
          Rails.logger.error("[Plugin::Policy] repository filter #{filter} failed closed: #{error.class}: #{error.message}")
          visible.none
        end
      end

      def self.fail_closed?(restrictions) = restrictions.any? { |entry| entry.equal?(FAIL_CLOSED) }
    end
  end
end
