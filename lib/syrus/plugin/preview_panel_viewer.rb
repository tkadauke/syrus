module Syrus
  module Plugin
    # Marker interface for a plugin that teaches the preview panel to render a
    # content kind core does not know about.
    #
    # `PreviewPanel` is a generic multi-format viewer -- html, markdown, pdf,
    # image (JOB-3864) -- but the mapping from a file to a viewer kind was a
    # hardcoded switch in `PreviewPanel::EntryMetadata`, so every new kind
    # meant editing core. A plugin declares its own:
    #
    #   def self.viewer_kinds
    #     [ { kind: "mermaid", extensions: %w[.mmd], content_types: %w[text/vnd.mermaid] } ]
    #   end
    #
    # Core's built-in kinds win: a plugin extends the set, it does not
    # reinterpret a file core already knows how to show. The frontend renders
    # an unrecognised kind through its existing source-text fallback, so a
    # backend-only registration degrades rather than breaking the panel.
    module PreviewPanelViewer
      def self.included(base) = base.extend(self)

      # Each entry: { kind:, extensions: [], content_types: [] }. `kind` is the
      # string the panel payload carries to the frontend.
      def viewer_kinds = []
    end
  end
end
