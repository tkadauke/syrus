module Mockups
  # Published mockups outlive their chat sidebar tabs. Keep their immutable
  # panel versions servable after the underlying panel has been closed.
  class PreviewPanelRetention
    include Syrus::Plugin::PreviewPanelRetention

    def self.retains?(panel)
      Mockup.exists?(preview_panel_id: panel.id)
    end
  end
end
