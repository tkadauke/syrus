class JobDependency
  module SatisfactionModes
    class Base
      def initialize(dependency)
        @dependency = dependency
      end

      def dependency_succeeded?
        raise NotImplementedError
      end

      def execution_dependency_satisfied?
        dependency_succeeded?
      end

      def terminal_unsuccessful_for_execution?
        return false if dependency_succeeded?

        if dependency.depends_on_job
          dependency.depends_on_job.closed?
        elsif dependency.depends_on_epic
          dependency.depends_on_epic.archived?
        else
          false
        end
      end

      def validate!
        true
      end

      private

      attr_reader :dependency
    end
  end
end
