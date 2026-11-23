# frozen_string_literal: true

module Syrus
  module Plugin
    # Data-governance hooks: retention definitions, purge contributors, and
    # retained-preview-panel decisions.
    #
    # Composition is collect for retention and purge: every enabled contributor
    # participates, and a retention run or purge must account for all of them.
    # A contributor that cannot be resolved, raises, times out, trips its
    # circuit breaker, or returns an invalid value contributes UNAVAILABLE
    # instead of dropping out silently, so callers report it and still run the
    # other contributors:
    #
    # - Retention: `RetentionPolicyRegistry` logs an error for the failing
    #   provider and still returns every other provider's definitions.
    # - Purge: `PluginPurge#other_data` lists a contributor that cannot report,
    #   and `purge!` records a line for one that failed to remove its data,
    #   while every other contributor still reports and removes.
    # - Preview-panel retention is a boolean any-of decision; a provider that
    #   declines simply does not retain the panel.
    module DataPolicy
      # Marker standing in for a contributor that could not be evaluated.
      UNAVAILABLE = Module.new do
        def self.inspect = "Syrus::Plugin::DataPolicy::UNAVAILABLE"
        def self.name = "Syrus::Plugin::DataPolicy::UNAVAILABLE"
      end

      CAPABILITY_FOR_LEGACY = {
        retention_policy: :retention_policies,
        purge_contributor: :purge_contributors,
        preview_panel_retention: :preview_panel_retentions
      }.freeze

      INTERFACES = {
        retention_policies: -> { RetentionPolicy },
        purge_contributors: -> { PurgeContributor },
        preview_panel_retentions: -> { PreviewPanelRetention }
      }.freeze

      def self.provider(key:, display_name:, **contributions) =
        ContributionProvider.build(key:, display_name:, interfaces: INTERFACES, **contributions)

      def self.retention_policies = contributions(:retention_policies)
      def self.purge_contributors = contributions(:purge_contributors)
      def self.preview_panel_retentions = contributions(:preview_panel_retentions)

      def self.unavailable?(entry) = entry.equal?(UNAVAILABLE)

      def self.contributions(capability)
        Dispatch.call(:data_policy, capability, Context::HookContext.new).flatten.compact
      end
      private_class_method :contributions
    end
  end
end
