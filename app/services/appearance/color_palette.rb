require "json"

module Appearance
  module ColorPalette
    PATH = Rails.root.join("config/appearance/colors.json")

    module_function

    def entries
      @entries ||= JSON.parse(PATH.read).fetch("colors").map(&:freeze).freeze
    end

    def keys = entries.map { |entry| entry.fetch("key") }

    def fetch(key)
      entries_by_key.fetch(key.to_s)
    end

    def default_key(handle)
      normalized = handle.to_s.downcase
      hash = normalized.each_byte.reduce(2_166_136_261) { |memo, byte| ((memo ^ byte) * 16_777_619) & 0xffff_ffff }
      keys.fetch(hash % keys.length)
    end

    def text_colors
      @text_colors ||= JSON.parse(PATH.read).fetch("chat_text").freeze
    end

    def entries_by_key
      @entries_by_key ||= entries.index_by { |entry| entry.fetch("key") }.freeze
    end
    private_class_method :entries_by_key
  end
end
