module Syrus
  module Plugin
    # Metadata-only UI and audit contributions. Component keys are resolved by
    # the frontend's convention-based plugin loaders; payloads must be safe to
    # retain and render after the provider is disabled or removed.
    module ReviewPresentationContributor
      def self.included(base) = base.extend(DefaultMethods)

      module DefaultMethods
        def target_editors = []
        def evidence_renderers = []
        def audit_renderers = []
        def settings_summaries = []
        def translations = []
      end
    end
  end
end
