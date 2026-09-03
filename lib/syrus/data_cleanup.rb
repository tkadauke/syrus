module Syrus
  # Where a plugin says "when this core record is destroyed, these rows of mine
  # go with it".
  #
  # This replaces injecting `has_many ..., dependent: :destroy` onto core
  # models. Injection meant a plugin mutating a core class, made
  # `reflect_on_all_associations` depend on which gems were installed, and
  # could not be undone -- which is why those injections carry a
  # `reflect_on_association` guard.
  #
  # Registrations are deliberately **not** gated on the plugin being enabled.
  # Disabling a plugin hides a feature; it does not delete the rows, and those
  # rows still need to go when their parent does. Enablement gates behaviour,
  # installation gates ownership -- and cleanup is ownership. (This is also why
  # it is not a `:domain_subscriber`: those are enabled-filtered.)
  module DataCleanup
    Registration = Struct.new(:model_name, :label, :cleanup, keyword_init: true)

    @mutex = Mutex.new
    @registrations = []

    class << self
      # `cleanup` receives the record being destroyed. Returns the teardown
      # that removes this registration again.
      def register(model_name, label, &cleanup)
        raise ArgumentError, "cleanup block required" unless cleanup

        registration = Registration.new(model_name: model_name.to_s, label: label.to_s, cleanup: cleanup)
        @mutex.synchronize { @registrations << registration }

        -> { @mutex.synchronize { @registrations.delete(registration) } }
      end

      def registrations_for(model_name)
        Syrus::Installer.sync!
        name = model_name.to_s
        @mutex.synchronize { @registrations.select { |r| r.model_name == name } }
      end

      # Runs every registration for the record's class. A failing cleanup must
      # not abort the destroy half-done, so it is logged and the rest continue;
      # the reconciler-style repair paths this app already relies on are a
      # better place to notice leftovers than a raise mid-transaction.
      def run!(record)
        registrations_for(record.class.name).each do |registration|
          registration.cleanup.call(record)
        rescue StandardError => e
          Rails.logger.error("[Syrus::DataCleanup] #{registration.label} failed for #{record.class}##{record.id}: #{e.class}: #{e.message}")
        end
      end

      def reset! = @mutex.synchronize { @registrations = [] }
    end
  end
end
