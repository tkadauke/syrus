module PluginRuntime
  # The last reconcile's view of each service, shared by web and worker through
  # Rails.cache.
  #
  # endpoint_for runs on request paths -- the git mirror is consulted while a
  # page renders -- so answering it must never cost a network call. The
  # reconcile tick does the talking and writes the result here.
  #
  # The TTL is the safety property, not a performance knob. If the ticks stop
  # -- the plugin disabled, the scheduler wedged -- entries expire and every
  # service reads as unavailable, so callers fall back to their slow path
  # instead of being handed an address nobody has checked in an hour.
  module StatusCache
    TTL = 5.minutes

    def self.write(status)
      Rails.cache.write(key(status.service), status.to_h, expires_in: TTL)
      status
    end

    def self.read(name)
      attributes = Rails.cache.read(key(name))
      attributes && ServiceStatus.new(**attributes.symbolize_keys)
    end

    def self.delete(name)
      Rails.cache.delete(key(name))
    end

    def self.key(name)
      "syrus:plugin_runtime:status:#{name}"
    end
  end
end
