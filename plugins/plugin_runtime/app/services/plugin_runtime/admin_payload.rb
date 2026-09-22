module PluginRuntime
  # What the admin page shows: every plugin service, its live state, and
  # which actions apply.
  #
  # On a managed install the page asks the runtime manager directly, so what
  # it shows is current rather than up to a minute old; if the manager cannot
  # be reached it falls back to the last reconcile's view and says so. On an
  # external install it shows the last health checks, read-only.
  class AdminPayload
    def initialize(configuration: Configuration.current, client: nil)
      @configuration = configuration
      @client = client
    end

    def as_json(*)
      desired = DesiredServices.all
      live, manager_error = live_statuses
      held = Holds.all

      services = desired.map do |entry|
        status = live[entry.name] || cached(entry)
        row(status, plugin: entry.plugin, desired: true, held: held.include?(entry.name))
      end
      # Managed containers no enabled plugin wants: removed on the next
      # reconcile, but visible until then.
      (live.keys - desired.map(&:name)).each do |name|
        services << row(live[name], plugin: live[name][:plugin], desired: false, held: false)
      end

      {
        mode: @configuration.managed? ? "managed" : "external",
        manageable: @configuration.managed?,
        manager_error: manager_error,
        services: services.sort_by { |service| service[:service] }
      }
    end

    private

    def live_statuses
      return [ {}, nil ] unless @configuration.managed?

      statuses = client.list.to_h do |payload|
        [ payload["service"], payload.symbolize_keys.slice(:service, :plugin, :state, :endpoint, :image, :error, :pull, :container_id) ]
      end
      [ statuses, nil ]
    rescue Client::Error => e
      [ {}, e.message ]
    end

    def cached(entry)
      status = StatusCache.read(entry.name)
      return { service: entry.name, state: "pending" } unless status

      status.to_h.slice(:service, :state, :endpoint, :image, :error, :pull, :checked_at)
    end

    def row(status, plugin:, desired:, held:)
      status.merge(
        plugin: plugin,
        desired: desired,
        held: held,
        actions: actions_for(status, desired: desired)
      )
    end

    def actions_for(status, desired:)
      return [] unless @configuration.managed? && desired

      running = %w[running starting unhealthy].include?(status[:state])
      actions = running ? %w[stop restart] : %w[start]
      actions << "logs" if status[:container_id].present? || running || status[:state] == "stopped"
      actions
    end

    def client
      @client ||= Client.new(url: @configuration.manager_url, token: @configuration.manager_token)
    end
  end
end
