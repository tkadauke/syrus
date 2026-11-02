module SyrusBrowser
  # Device profiles for browser_emulate. One small table; add a row to add a
  # preset. Every preset lists the complete emulation state it applies, so
  # selecting one is a full switch of device rather than a partial overlay.
  module EmulationPresets
    DESKTOP = {
      viewport: { width: 1280, height: 720 },
      device_scale_factor: 1,
      is_mobile: false,
      has_touch: false,
      user_agent: "",
      safe_area_insets: { top: 0, right: 0, bottom: 0, left: 0 },
      color_scheme: nil,
      reduced_motion: nil
    }.freeze

    IPHONE_15_PRO = DESKTOP.merge(
      viewport: { width: 393, height: 852 },
      device_scale_factor: 3,
      is_mobile: true,
      has_touch: true,
      user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 " \
                  "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
      safe_area_insets: { top: 59, right: 0, bottom: 34, left: 0 }
    ).freeze

    PRESETS = {
      "desktop" => DESKTOP,
      "iphone-15-pro" => IPHONE_15_PRO
    }.freeze

    def self.names
      PRESETS.keys
    end

    def self.fetch(name)
      PRESETS.fetch(name.to_s)
    end
  end
end
