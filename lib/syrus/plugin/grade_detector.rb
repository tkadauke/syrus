module Syrus
  module Plugin
    # Interface for `:grade_detector` extension points. Language/framework
    # plugins use this to propose complete `.syrus.yml` grader candidates for
    # a repository that has not written custom grade config yet.
    module GradeDetector
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def grade_candidates(repo_path)
          raise NotImplementedError, "#{self}.grade_candidates is required"
        end
      end

      def grade_candidates(repo_path)
        raise NotImplementedError, "#{self.class}#grade_candidates is required"
      end
    end
  end
end
