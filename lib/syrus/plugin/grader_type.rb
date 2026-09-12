module Syrus
  module Plugin
    # Interface for `:grader_type` extension points. Language/framework
    # plugins use this to turn a declarative `.syrus.yml` grader entry like
    # `type: rspec` into one or more concrete shell-backed grader steps.
    module GraderType
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def type_name
          raise NotImplementedError, "#{self}.type_name is required"
        end

        def grade_steps(config:, default_failures:)
          raise NotImplementedError, "#{self}.grade_steps is required"
        end
      end

      def type_name
        raise NotImplementedError, "#{self.class}#type_name is required"
      end

      def grade_steps(config:, default_failures:)
        raise NotImplementedError, "#{self.class}#grade_steps is required"
      end
    end
  end
end
