# Only sanctioned way to mutate a PreviewPanel. Wraps the record so the
# chat MCP plugin tool set (a later Job) and any future caller go through
# one place that keeps attachments and the live-update broadcast in sync,
# instead of poking PreviewPanel directly.
class PreviewPanel::Service
  def self.open!(chat_session:, title:, files: {}, entry_file: PreviewPanel::DEFAULT_ENTRY_FILENAME)
    panel = chat_session.preview_panels.create!(title: title, state: "open")
    new(panel).update!(files: files, entry_file: entry_file)
  end

  def initialize(panel)
    @panel = panel
  end

  attr_reader :panel

  def update!(files:, entry_file: PreviewPanel::DEFAULT_ENTRY_FILENAME)
    panel.create_version!(files, entry_file: entry_file)
    panel.broadcast_change!
    panel
  end

  def close!
    panel.update!(state: "closed")
    panel.broadcast_change!
    panel
  end

  def update_visibility!(visibility)
    panel.update!(visibility: visibility)
    panel.broadcast_change!
    panel
  end
end
