# The media kinds a chat can attach, core's own plus whatever plugins
# contribute through :chat_media_source.
module ChatMediaSources
  CORE_SOURCES = [ ChatMedia::ChatImageSource ].freeze

  def self.all
    CORE_SOURCES + Syrus::PluginRegistry.providers_for(:chat_media_source)
  end

  def self.kinds
    all.map { |source| source.chat_media_kind.to_s }
  end

  # Merged contributions to the chat UI's media panel.
  def self.panel(chat_session:)
    all.each_with_object({}) do |source, merged|
      merged.merge!(source.chat_media_panel(chat_session: chat_session).to_h)
    end
  end

  def self.for_kind(kind)
    all.find { |source| source.chat_media_kind.to_s == kind.to_s }
  end
end
