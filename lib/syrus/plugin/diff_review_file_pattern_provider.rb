module Syrus
  module Plugin
    # Interface for plugins that contribute noisy/generated file patterns to
    # diff review classification. Providers return hashes with:
    #
    #   { glob:, reason:, source: }
    #
    # `source` should be a stable short label such as a plugin or tool name.
    module DiffReviewFilePatternProvider
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def diff_review_file_patterns
          raise NotImplementedError, "#{name}.diff_review_file_patterns is required"
        end
      end
    end
  end
end
