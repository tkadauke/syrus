require "monitor"

module Syrus
  # Runs plugin installs, and re-runs them when the active plugin set changes.
  #
  # The registry used to be pure pull: every use site asked
  # `PluginRegistry.providers_for(...)` and re-derived the answer, and anything
  # expensive enough to cache had to be invalidated by hand. That produced a
  # steady supply of staleness bugs -- constants frozen at autoload, generation
  # counters, order-dependent leaks -- and, because nothing was ever installed,
  # disabling a plugin never actually removed anything.
  #
  # An installer instead *performs* the install and hands back the teardown
  # (see EffectScope). This is deliberately not Cordis's one-shot mount: Syrus
  # runs web pods, worker pods, MCP sidecars and `rails runner` as separate
  # processes, and an install performed in one cannot be disposed by an admin
  # click served by another. So each process syncs against the current plugin
  # state and re-applies when it moves -- useEffect-with-deps rather than a
  # fiber mount.
  # Lifetimes, so this does not get merged with Syrus::Plugin::EffectRegistry:
  # installs here are disposed and re-applied whenever the active plugin set
  # moves, while an EffectRegistry cleanup lives until its own plugin's
  # lifecycle events. Both are EffectScopes underneath; only the trigger
  # differs.
  module Installer
    Registration = Struct.new(:label, :plugin, :install, keyword_init: true)

    # A Monitor rather than a Mutex because installs re-enter: an install block
    # can touch a registry that is autoloaded for the first time right then,
    # and a KindRegistry defines its own installer entry when it is
    # constructed. With a plain Mutex that raised
    # `ThreadError: deadlock; recursive locking` inside apply!, which is
    # rescued per-registration -- so every scoped effect silently failed to
    # install while sync! still recorded the fingerprint as applied.
    @mutex = Monitor.new
    @registrations = {}
    @scope = nil
    @applied_fingerprint = nil

    class << self
      # Label-keyed so a Zeitwerk reload replaces an installer rather than
      # stacking a second copy of it.
      #
      # `plugin:` scopes the install to that plugin being enabled, which is the
      # common case — it saves every plugin writing the same guard, and means
      # disabling the plugin disposes its installs without the plugin having to
      # notice.
      def define(label, plugin: nil, &install)
        @mutex.synchronize do
          @registrations[label.to_s] = Registration.new(label: label.to_s, plugin: plugin&.to_s, install: install)
          @applied_fingerprint = nil
        end
      end

      def defined_labels = @mutex.synchronize { @registrations.keys.dup }

      # Cheap on the hot path: computes the fingerprint and returns unless it
      # moved. Callers may treat this as "make sure what is installed matches
      # what is enabled".
      def sync!
        # An install that reads a registry which itself syncs on read would
        # otherwise deadlock on a non-reentrant mutex. Nested calls are a
        # no-op: the outer apply! is already installing.
        return false if Thread.current[:syrus_installer_applying]

        current = fingerprint

        @mutex.synchronize do
          return false if @applied_fingerprint == current

          Thread.current[:syrus_installer_applying] = true
          begin
            apply!(current)
          ensure
            Thread.current[:syrus_installer_applying] = nil
          end
          true
        end
      end

      # Disposes everything and forgets the applied state, so the next sync!
      # reinstalls from scratch. Used by the spec harness and by reset!.
      def reset!
        @mutex.synchronize do
          @scope&.dispose
          @scope = nil
          @applied_fingerprint = nil
        end
      end

      # Registrations are made once, where the registering code loads, so
      # clearing them permanently is not recoverable inside a running process.
      # Specs that need an empty installer take a snapshot and put it back.
      def snapshot = @mutex.synchronize { @registrations.dup }

      def restore(snapshot)
        @mutex.synchronize do
          @scope&.dispose
          @scope = nil
          @applied_fingerprint = nil
          @registrations = snapshot.dup
        end
      end

      def clear_registrations!
        restore({})
      end

      private

      # A plain integer compare, because this runs on every kind-table read.
      # Same-process enable/disable bumps the generation directly; a disable in
      # another process bumps it when the plugin-record cache expires and the
      # enabled set turns out to have changed (see
      # PluginRegistry#plugin_records_by_name). Putting a TTL-cached database
      # read here instead would be a per-read query in test, where the TTL is
      # zero.
      def fingerprint
        Syrus::PluginRegistry.generation
      end

      # nil means "cannot tell yet" (no plugin_records table during early boot
      # or on a fresh database); installs run rather than being suppressed,
      # matching how providers_for degrades.
      def enabled_plugin_names
        Syrus::PluginRegistry.all_plugins.select(&:enabled?).map(&:name).to_set
      rescue StandardError
        nil
      end

      def apply!(current)
        @scope&.dispose
        @scope = EffectScope.new(label: "installer")
        @applied_fingerprint = current

        active = enabled_plugin_names

        # A snapshot, because an install can define a new registration: a
        # KindRegistry constructed for the first time during an install adds
        # its own entry. Those are picked up by the next sync -- `define` nils
        # the applied fingerprint, so one is already guaranteed.
        @registrations.values.each do |registration|
          next if registration.plugin && active && !active.include?(registration.plugin)

          child = @scope.child(label: registration.label)
          begin
            registration.install.call(child)
          rescue StandardError => e
            Rails.logger.error("[Syrus::Installer] install #{registration.label.inspect} failed: #{e.class}: #{e.message}")
            child.dispose
          end
        end
      end
    end
  end
end
