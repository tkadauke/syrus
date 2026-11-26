module SyrusCoverage
  # Hit maps are large and only useful while a change is under review. The
  # plugin runs its own daily TTL sweep (see `tick_interval` in the manifest)
  # instead of a host recurring.yml entry, so removing the plugin removes the
  # schedule with it.
  class Callbacks
    include Syrus::Host::Callbacks

    def self.on_tick
      SyrusCoverage::HitMapTtlPruneJob.perform_later
    end
  end
end
