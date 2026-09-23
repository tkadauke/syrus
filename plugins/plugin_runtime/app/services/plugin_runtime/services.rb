module PluginRuntime
  # What container-backed plugins call.
  #
  #   PluginRuntime::Services.endpoint_for("git-mirror")  # => "http://git-mirror:8080" or nil
  #
  # The same call answers on a Compose install (the runtime manager runs the
  # service) and on Kubernetes (an operator does), so a plugin never branches
  # on how Syrus was deployed.
  module Services
    def self.driver(configuration: Configuration.current)
      if configuration.managed?
        ManagedDriver.new(client: Client.new(url: configuration.manager_url, token: configuration.manager_token))
      else
        ExternalDriver.new(configuration: configuration)
      end
    end

    def self.reconcile!(driver: self.driver)
      driver.reconcile(DesiredServices.all, privileged: DesiredPrivilegedServices.all)
    end

    # The service's address, or nil when it is not usable right now.
    #
    # Never makes a network call: it reads what the last reconcile recorded, so
    # it is safe on a request path. nil covers everything from "still pulling"
    # to "this plugin is disabled", and the caller's answer to all of them is
    # the same -- carry on without the service.
    def self.endpoint_for(name)
      status = status_for(name)
      status&.available? ? status.endpoint : nil
    end

    def self.status_for(name)
      # Disabling the runtime makes every service unavailable at once, rather
      # than each lingering until its cache entry expires.
      return nil unless PluginRuntime.enabled?

      StatusCache.read(name.to_s)
    end

    # Every desired service with its last known status, for display.
    def self.statuses
      (DesiredServices.all + DesiredPrivilegedServices.all).map do |entry|
        StatusCache.read(entry.name) ||
          ServiceStatus.build(service: entry.name, plugin: entry.plugin, mode: driver.mode, state: "pending")
      end
    end
  end
end
