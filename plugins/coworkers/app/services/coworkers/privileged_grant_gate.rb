module Coworkers
  class PrivilegedGrantGate
    CONFINEMENT_RUNTIME = "confined_coworker".freeze
    Availability = Data.define(:available?, :reason)

    class << self
      def turn_admission(coworker)
        return {} unless confinement_required?(coworker)
        return {} if current_worker_confined?

        worker = confined_workers.first
        return { outcome: "confinement_unavailable" } unless worker

        { queue: ::Workflow.resume_queue_name(worker.hostname) }
      end

      def availability(descriptor)
        return Availability.new(available?: true, reason: nil) unless descriptor.privileged
        return Availability.new(available?: false, reason: "confinement_unavailable") unless confined_worker_available?
        return Availability.new(available?: false, reason: "broker_authorization_unavailable") unless broker_authorization_available?

        Availability.new(available?: true, reason: nil)
      end

      def ensure_available!(descriptor)
        result = availability(descriptor)
        raise Unavailable, result.reason unless result.available?
      end

      def allowed_capabilities(coworker)
        coworker.grants.filter_map do |grant|
          descriptor = Coworkers::GrantCatalog.fetch(grant.capability)
          grant.capability if availability(descriptor).available?
        rescue KeyError
          nil
        end
      end

      def confinement_required?(coworker)
        privileged_names = Coworkers::GrantCatalog.all.select(&:privileged).map(&:name)
        coworker.grants.where(capability: privileged_names).exists?
      end

      private

      def current_worker_confined?
        Array(WorkerCapabilities.current.dig(:capabilities, "runtime")).include?(CONFINEMENT_RUNTIME)
      end

      def confined_worker_available?
        confined_workers.any?
      end

      def confined_workers
        InstanceVersion.fresh.where(role: "worker").select do |worker|
          Array(WorkerCapabilities.normalize(worker.capabilities)["runtime"]).include?(CONFINEMENT_RUNTIME)
        end
      rescue ActiveRecord::StatementInvalid
        []
      end

      def broker_authorization_available?
        manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "credential_store" }
        manifest&.enabled? && Syrus::PluginRegistry.health.healthy?(manifest.name)
      end
    end

    class Unavailable < ArgumentError; end
  end
end
