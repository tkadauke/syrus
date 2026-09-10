class TargetGraph
  module ImportFailurePolicy
    class Base
      def self.for(name)
        {
          "strict" => Strict,
          "warn" => Warn
        }.fetch(name.to_s).new
      rescue KeyError
        raise ArgumentError, "unknown target graph import failure policy #{name.inspect}"
      end

      def handle(error_message:, compiler:)
        raise NotImplementedError, "#{self.class}#handle is required"
      end
    end

    class Strict < Base
      def handle(error_message:, compiler:)
        raise TargetGraph::ValidationError, error_message
      end
    end

    class Warn < Base
      def handle(error_message:, compiler:)
        compiler.record_import_error(error_message)
      end
    end
  end
end
