module Syrus
  module Plugin
    # Interface for plugins that enrich the Job review tab with diff-range
    # annotations, side-panel/card payloads, actions, and aggregate counts.
    #
    # Implementations return a hash-like payload from:
    #
    #   .review_annotations(job:, user:, version:, base_sha:, head_sha:, files:)
    #
    # Core normalizes these optional keys:
    #   annotations: { "path.rb" => { "12" => [{ id:, title:, body:, ... }] } }
    #   panels:      [{ id:, component:, props:, ... }]
    #   actions:     [{ id:, label:, href:, method:, component:, props:, ... }]
    #   counts:      [{ id:, label:, value:, tone:, ... }]
    module DiffReviewAnnotationProvider
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def review_annotations(job:, user:, version:, base_sha:, head_sha:, files:)
          raise NotImplementedError, "#{name}.review_annotations is required"
        end
      end
    end
  end
end
