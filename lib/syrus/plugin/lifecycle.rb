# frozen_string_literal: true

module Syrus
  module Plugin
    # Lifecycle hooks: plugin lifecycle callbacks, domain-event subscribers, and
    # the reversible installation effects that `Syrus::Installer` runs.
    #
    # Composition is broadcast. Every enabled, healthy plugin's hook runs; none
    # claims, none is skipped because another one failed.
    #
    # Failure rule, preserved from the legacy extension points:
    #
    # - Callbacks: a failing `on_boot` drains the effects that plugin registered
    #   so far and is logged; the next plugin still boots. `on_shutdown` always
    #   drains. Enable/disable run through `PluginLifecycleJob`, which drains on
    #   failure and re-raises so the job's retry machinery sees it.
    # - Domain subscribers: each subscriber is invoked inside its own
    #   `PluginInvocation`, so one subscriber raising never reaches the
    #   publisher or the other subscribers. Async delivery is one job per
    #   subscriber.
    #
    # The capabilities return the established behavior modules; the per-hook
    # isolation above stays with the core callers that invoke them.
    module Lifecycle
      CAPABILITY_FOR_LEGACY = {
        callbacks: :callback_providers,
        domain_subscriber: :domain_subscribers
      }.freeze

      INTERFACES = {
        callback_providers: -> { Callbacks },
        domain_subscribers: -> { DomainSubscriber }
      }.freeze

      def self.provider(key:, display_name:, **contributions) =
        ContributionProvider.build(key:, display_name:, interfaces: INTERFACES, **contributions)

      # Callback modules of every enabled, healthy plugin, in plugin priority order.
      def self.callback_providers
        Dispatch.call(:lifecycle, :callback_providers, Context::HookContext.new).flatten.compact
      end

      # Callback modules of one plugin regardless of its enablement: on_disable
      # must still reach a plugin that has just been turned off.
      def self.callback_providers_for(manifest)
        Syrus::PluginRegistry.manifest_providers_for(manifest, :callbacks)
      end

      # Domain-subscriber modules of every enabled, healthy plugin.
      def self.domain_subscribers
        Dispatch.call(:lifecycle, :domain_subscribers, Context::HookContext.new).flatten.compact
      end

      # Plugin-facing entry point for reversible installation effects (the
      # `while_enabled` and `always` blocks). `Syrus::Installer` remains the
      # engine; core registries that install their own contributions keep
      # calling it directly.
      def self.define_effect(label, plugin:, requires:, &install) =
        Syrus::Installer.define(label, plugin:, requires:, &install)
    end
  end
end
