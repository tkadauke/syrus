# The media kinds a chat can attach, core's own plus whatever plugins
# contribute through :chat_media_source.
module ChatMediaSources
  CORE_SOURCES = [ ChatMedia::ChatImageSource ].freeze

  def self.all
    CORE_SOURCES + Syrus::Plugin::ChatIntegration.contributions(:media_sources)
  end

  def self.kinds
    all.filter_map { |source| invoke(source, :chat_media_kind, nil) { source.chat_media_kind }&.to_s }
  end

  # Merged contributions to the chat UI's media panel.
  def self.panel(chat_session:)
    all.each_with_object({}) do |source, merged|
      merged.merge!(invoke(source, :chat_media_panel, {}) { source.chat_media_panel(chat_session: chat_session) }.to_h)
    end
  end

  def self.for_kind(kind)
    all.find { |source| invoke(source, :chat_media_kind, nil) { source.chat_media_kind }&.to_s == kind.to_s }
  end

  def self.invoke(source, operation, decline, &block)
    return block.call if CORE_SOURCES.include?(source)

    Syrus::PluginInvocation.value(Syrus::PluginInvocation.call(
      extension_point: :chat_media_source, provider: source, operation:, on_decline: decline, &block
    ))
  end
  private_class_method :invoke
end
