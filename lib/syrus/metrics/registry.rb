module Syrus
  module Metrics
    # Holds every declared metric and the live instrument behind it.
    #
    # Declaration is distributed -- core metrics live next to the subsystem they
    # measure, plugin metrics live in the plugin manifest -- so there is no one
    # file to read and the registry has to be the strict part. It enforces:
    # unique names, allowlisted labels, and the plugin namespace prefix.
    class Registry
      def initialize
        @mutex = Mutex.new
        @definitions = {}
        @instruments = {}
      end

      # Evaluates a declaration block and registers everything in it. Returns
      # the fully-qualified names, which is what a plugin hands back as its
      # teardown.
      def declare(owner:, prefix: nil, &block)
        raise ArgumentError, "declare requires a block" unless block

        collected = Declaration.new(owner: owner, prefix: prefix).tap { |d| d.instance_eval(&block) }.definitions
        collected.each(&:validate!)

        @mutex.synchronize do
          collected.each do |definition|
            existing = @definitions[definition.name]
            if existing
              # Loudly, because silent shadowing between a plugin and core is
              # near-undebuggable from a dashboard: you see one series and have
              # no way to tell which declaration produced it. A reload
              # re-registering the identical declaration is fine.
              next if same_declaration?(existing, definition)

              raise Error,
                    "metric #{definition.name} is already declared by #{existing.owner} " \
                    "(#{existing.type}); #{definition.owner} cannot redeclare it as #{definition.type}"
            end

            @definitions[definition.name] = definition
            @instruments[definition.name] = build_instrument(definition)
          end
        end

        collected.map(&:name)
      end

      # Plugin teardown. Removing the definition removes the series from the
      # next scrape, which is the correct reading of a disabled plugin: not
      # "zero", which would mean enabled-and-unused, but absent.
      def undeclare(names)
        @mutex.synchronize do
          Array(names).each do |name|
            @definitions.delete(name)
            @instruments.delete(name)
          end
        end
      end

      def definitions = @mutex.synchronize { @definitions.values.sort_by(&:name) }
      def declared?(name) = @mutex.synchronize { @definitions.key?(name.to_sym) }

      def fetch(name, expected_type)
        name = name.to_sym
        instrument = @mutex.synchronize { @instruments[name] }

        if instrument.nil?
          # In development and test an undeclared metric is a programming
          # error worth surfacing immediately. In production it must not take
          # down the caller -- a metrics bug failing a Run is a far worse
          # outcome than a missing series -- so it degrades to a no-op that
          # still logs.
          raise UnknownMetric, "metric #{name} is not declared" if raise_on_unknown?

          warn_once(name)
          return NullInstrument.new(name, expected_type)
        end

        unless instrument.type == expected_type
          raise UnknownMetric, "metric #{name} is a #{instrument.type}, not a #{expected_type}"
        end

        instrument
      end

      private

      def build_instrument(definition)
        case definition.type
        when :counter then Counter.new(definition)
        when :gauge then Gauge.new(definition)
        when :histogram then Histogram.new(definition)
        end
      end

      def same_declaration?(a, b)
        a.type == b.type && a.tags == b.tags && a.owner.to_s == b.owner.to_s
      end

      def raise_on_unknown?
        return true unless defined?(::Rails) && ::Rails.respond_to?(:env)

        ::Rails.env.local?
      end

      def warn_once(name)
        @warned ||= {}
        return if @warned[name]

        @warned[name] = true
        return unless defined?(::Rails) && ::Rails.respond_to?(:logger)

        ::Rails.logger&.warn("[Syrus::Metrics] undeclared metric #{name} -- instrumentation dropped")
      end
    end
  end
end
