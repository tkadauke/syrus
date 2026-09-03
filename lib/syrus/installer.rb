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
  module Installer
    Registration = Struct.new(:label, :install, keyword_init: true)

    @mutex = Mutex.new
    @registrations = {}
    @scope = nil
    @applied_fingerprint = nil

    class << self
      # Label-keyed so a Zeitwerk reload replaces an installer rather than
      # stacking a second copy of it.
      def define(label, &install)
        @mutex.synchronize do
          @registrations[label.to_s] = Registration.new(label: label.to_s, install: install)
          @applied_fingerprint = nil
        end
      end

      def defined_labels = @mutex.synchronize { @registrations.keys.dup }

      # Cheap on the hot path: computes the fingerprint and returns unless it
      # moved. Callers may treat this as "make sure what is installed matches
      # what is enabled".
      def sync!
        current = fingerprint

        @mutex.synchronize do
          return false if @applied_fingerprint == current

          apply!(current)
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

      def clear_registrations!
        @mutex.synchronize do
          @scope&.dispose
          @scope = nil
          @applied_fingerprint = nil
          @registrations = {}
        end
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

      def apply!(current)
        @scope&.dispose
        @scope = EffectScope.new(label: "installer")
        @applied_fingerprint = current

        @registrations.each_value do |registration|
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
