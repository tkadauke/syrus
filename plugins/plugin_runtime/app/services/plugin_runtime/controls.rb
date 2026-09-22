module PluginRuntime
  # Operator actions on a plugin service, from the admin page.
  #
  # Only managed services (Docker Compose, through the runtime manager) can be
  # acted on. On Kubernetes an operator runs the services, so Syrus has
  # nothing to stop -- and should not be able to.
  #
  # Stopping holds the service (see Holds) so reconciling does not start it
  # again; Start and Restart release the hold. While a service is stopped its
  # plugin carries on without it, exactly as if it were still starting.
  class Controls
    class Error < StandardError; end
    class NotManaged < Error; end
    class UnknownService < Error; end

    DEFAULT_LOG_TAIL = 200

    def initialize(configuration: Configuration.current, client: nil)
      @configuration = configuration
      @client = client
    end

    def stop!(name)
      entry = entry_for(name)
      Holds.hold!(entry.name)
      write(entry, client.stop(entry.name))
    rescue Client::NotFound
      # Nothing to stop yet (still pulling); the hold keeps it from starting.
      read(entry)
    end

    def start!(name)
      entry = entry_for(name)
      Holds.release!(entry.name)
      driver.ensure_now(entry)
    end

    def restart!(name)
      entry = entry_for(name)
      Holds.release!(entry.name)
      write(entry, client.restart(entry.name))
    rescue Client::NotFound
      driver.ensure_now(entry)
    end

    # Deletes a plugin service's stored data. The manager refuses while the
    # volume's service still has a container (Client::Conflict), so this only
    # ever removes data a disabled or removed plugin left behind.
    def remove_volume!(name)
      raise NotManaged, "plugin services are managed outside Syrus in this deployment" unless @configuration.managed?

      client.remove_volume(name)
    end

    def logs(name, tail: DEFAULT_LOG_TAIL)
      entry = entry_for(name)
      client.logs(entry.name, tail: tail.to_i.clamp(1, 5000))
    end

    private

    def entry_for(name)
      raise NotManaged, "plugin services are managed outside Syrus in this deployment" unless @configuration.managed?

      DesiredServices.all.find { |entry| entry.name == name.to_s } ||
        raise(UnknownService, "no enabled plugin provides a service named #{name}")
    end

    def write(entry, payload)
      StatusCache.write(ServiceStatus.from_manager(payload, plugin: entry.plugin))
    end

    def read(entry)
      write(entry, client.status(entry.name))
    end

    def client
      @client ||= Client.new(url: @configuration.manager_url, token: @configuration.manager_token)
    end

    def driver
      ManagedDriver.new(client: client)
    end
  end
end
