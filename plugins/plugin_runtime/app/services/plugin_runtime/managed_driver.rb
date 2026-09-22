module PluginRuntime
  # Docker Compose: the runtime manager pulls, starts and removes services.
  class ManagedDriver
    def initialize(client:)
      @client = client
    end

    def mode = "managed"

    # Ensure every desired service, then remove managed services nobody wants
    # any more -- which is what disabling a plugin amounts to.
    #
    # If the manager cannot be reached, nothing is removed. Acting on a partial
    # view is how a monitoring blip turns into every plugin's container being
    # torn down; waiting a minute for the next tick costs nothing.
    #
    # A service an operator stopped (Holds) is not ensured -- that would start
    # it again -- only re-read, so its cached status stays current.
    def reconcile(desired)
      Holds.prune!(desired.map(&:name))
      held = Holds.all
      desired.each do |entry|
        StatusCache.write(held.include?(entry.name) ? read_one(entry) : ensure_one(entry))
      end
      remove_unwanted(desired)
    rescue Client::Unavailable => e
      desired.each do |entry|
        StatusCache.write(ServiceStatus.build(service: entry.name, plugin: entry.plugin, mode: mode,
                                              state: "unavailable", error: e.message))
      end
    end

    # Ensures one service right away and records its status -- what the admin
    # page's Start and Restart use instead of waiting for the next tick.
    def ensure_now(entry)
      StatusCache.write(ensure_one(entry))
    end

    private

    def read_one(entry)
      ServiceStatus.from_manager(@client.status(entry.name), plugin: entry.plugin)
    rescue Client::Unavailable
      raise
    rescue Client::Error => e
      ServiceStatus.build(service: entry.name, plugin: entry.plugin, mode: mode, state: "error", error: e.message)
    end

    def ensure_one(entry)
      spec = request_for(entry)
      ServiceStatus.from_manager(@client.ensure_service(entry.name, spec), plugin: entry.plugin)
    rescue Client::Refused => e
      ServiceStatus.build(service: entry.name, plugin: entry.plugin, mode: mode, state: "error",
                          error: "refused by the runtime manager: #{e.message}")
    rescue Client::Unavailable
      raise
    rescue StandardError => e
      # The contributor's service_spec raised. Report it on that service and
      # leave the others alone.
      ServiceStatus.build(service: entry.name, plugin: entry.plugin, mode: mode, state: "error",
                          error: "#{entry.plugin} could not build its service spec: #{e.class}: #{e.message}")
    end

    def request_for(entry)
      spec = entry.provider.service_spec.deep_stringify_keys
      spec["env"] = spec["env"].to_h.transform_values(&:to_s) if spec.key?("env")
      spec.merge("plugin" => entry.plugin)
    end

    # A desired service whose spec failed to build is still desired: it is in
    # `desired` by name regardless, so a broken spec never tears down a working
    # container.
    def remove_unwanted(desired)
      wanted = desired.map(&:name).to_set
      @client.list.each do |status|
        name = status["service"]
        next if name.blank? || wanted.include?(name)

        @client.remove(name)
        StatusCache.delete(name)
      end
    end
  end
end
