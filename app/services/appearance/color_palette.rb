require "json"
require "set"

module Appearance
  module ColorPalette
    PATH = Rails.root.join("config/appearance/colors.json")
    HEX_PATTERN = /\A#[0-9A-F]{6}\z/i

    module_function

    def families = config.fetch("families")
    def entries = @entries ||= families.flat_map { |family| family.fetch("colors") }.freeze
    def hue_columns = config.fetch("hue_columns")
    def picker_tones = config.fetch("picker_tones")
    def default_agent_order = config.fetch("default_agent_order")
    def theme_colors = config.fetch("theme_colors")

    def valid_hex?(hex) = HEX_PATTERN.match?(hex.to_s)

    def nearest_color(hex)
      validate_hex!(hex)
      entries.min_by { |entry| color_distance(hex, entry.fetch("hex")) }
    end

    def next_default_color(used_hexes)
      used = Array(used_hexes).to_set { |hex| hex.to_s.upcase }
      default_agent_order.find { |hex| !used.include?(hex) }
    end

    def color_distance(first, second)
      validate_hex!(first)
      validate_hex!(second)
      a = oklab(first)
      b = oklab(second)
      Math.sqrt(a.zip(b).sum { |left, right| (left - right)**2 }) * 100
    end

    def config
      @config ||= JSON.parse(PATH.read).tap do |data|
        colors = data.fetch("families").flat_map { |family| family.fetch("colors") }
        raise "accent library must contain 72 colors" unless colors.size == 72
        raise "invalid accent hex" unless colors.all? { |color| valid_hex?(color.fetch("hex")) }
        raise "invalid theme hex" unless data.fetch("theme_colors").values.all? { |hex| valid_hex?(hex) }
      end.freeze
    end

    def validate_hex!(hex)
      raise ArgumentError, "expected #RRGGBB color" unless valid_hex?(hex)
    end
    private_class_method :validate_hex!

    def rgb(hex)
      value = hex.delete_prefix("#").to_i(16)
      [ (value >> 16) & 255, (value >> 8) & 255, value & 255 ]
    end
    private_class_method :rgb

    def linear(value)
      value /= 255.0
      value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055)**2.4
    end
    private_class_method :linear

    def oklab(hex)
      r, g, b = rgb(hex).map { |value| linear(value) }
      l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
      m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
      s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
      [
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
      ]
    end
    private_class_method :oklab
  end
end
