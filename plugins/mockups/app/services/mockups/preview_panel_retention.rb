module Mockups
  module PreviewPanelRetention
    include Syrus::Plugin::PreviewPanelRetention

    def self.retained_preview_panel?(panel)
      Mockup.exists?(preview_panel_id: panel.id)
    end
  end
end
