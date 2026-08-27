# Only sanctioned way to mutate a PreviewPanel. Wraps the record so the
# chat MCP plugin tool set (a later Job) and any future caller go through
# one place that keeps attachments and the live-update broadcast in sync,
# instead of poking PreviewPanel directly.
class PreviewPanel::Service
  def self.open!(chat_session:, title:, files: {})
    panel = chat_session.preview_panels.create!(title: title, state: "open")
    new(panel).update!(files: files)
  end

  def initialize(panel)
    @panel = panel
  end

  attr_reader :panel

  def update!(files:)
    panel.create_version!(files)
    panel.broadcast_change!
    panel
  end

  def close!
    panel.update!(state: "closed")
    panel.broadcast_change!
    panel
  end
end
