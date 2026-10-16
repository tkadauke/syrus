module Syrus
  module Plugin
    # Marker interface for plugins whose durable records keep a closed preview
    # panel useful after its transient chat tab has been dismissed.
    module PreviewPanelRetention
      def self.included(base) = base.extend(self)

      def retained_preview_panel?(_panel) = false
    end
  end
end
