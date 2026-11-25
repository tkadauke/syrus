module RuntimeImages
  module BuildNetwork
    Decision = Data.define(:allowed, :reason, :source_class, :host, :port, :allow_private) do
      def self.allow(rule, host:, port:)
        new(allowed: true, reason: "allowed", source_class: rule.source_class, host: host, port: port,
            allow_private: rule.source.allow_private?)
      end

      def self.deny(reason, host:, port:)
        new(allowed: false, reason: reason, source_class: nil, host: host, port: port, allow_private: false)
      end

      def allowed? = allowed
    end
  end
end
