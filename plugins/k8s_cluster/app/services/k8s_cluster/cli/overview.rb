module K8sCluster::Cli
  class Overview < Base
    def call(args:, flags:, user:)
      authorize!(user)
      payload = service(K8sCluster::Overview, cluster_for(flags["cluster"]), user).call(summary: false, namespace: nil)
      self.class.text([ metric_line("Nodes", payload[:nodes]), metric_line("Pods", payload[:pods]) ].join("\n"))
    end

    private

    def metric_line(label, section)
      return "#{label}: unavailable (#{value_or_dash(section[:message])})" unless section[:available]

      "#{label}: #{section[:total_cpu_millicores]} millicores, #{format_bytes(section[:total_memory_bytes])} across #{Array(section[:items]).length} item(s)"
    end

    def format_bytes(bytes)
      return "#{bytes}B" if bytes < 1024
      exponent = [ Math.log(bytes, 1024).floor, 5 ].min
      format("%.1f%ciB", bytes.to_f / (1024**exponent), "KMGTPE"[exponent - 1])
    end
  end
end
