module K8sCluster::Cli
  class Logs < Base
    def call(args:, flags:, user:)
      authorize!(user)
      payload = service(K8sCluster::Pods, cluster_for(flags["cluster"]), user).logs(args.fetch(0), namespace: flags.fetch("namespace"), container: flags["container"].presence, tail_lines: flags.fetch("tail", 200), previous: false, timestamps: false)
      self.class.raw_text(payload[:log])
    end
  end
end
