module K8sCluster
  class Callbacks
    include Syrus::Host::Callbacks

    def self.on_tick
      RefreshCredentialsJob.perform_later
    end
  end
end
