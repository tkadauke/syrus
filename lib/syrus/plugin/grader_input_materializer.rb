module Syrus
  module Plugin
    # Interface for synchronous pre-grader workspace inputs. Providers may
    # materialize optional files, such as runtime profiles, after workspace
    # setup and prepare-target dependencies but before the grader command runs.
    module GraderInputMaterializer
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def materialize_grader_inputs(context)
          raise NotImplementedError, "#{self}.materialize_grader_inputs is required"
        end
      end

      def materialize_grader_inputs(context)
        raise NotImplementedError, "#{self.class}#materialize_grader_inputs is required"
      end
    end
  end
end
