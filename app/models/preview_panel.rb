class PreviewPanel < ApplicationRecord
  STATES = %w[ open closed ].freeze
  DEFAULT_ENTRY_FILENAME = "index.html"

  belongs_to :chat_session
  has_many_attached :files

  validates :title, presence: true
  validates :state, presence: true, inclusion: { in: STATES }

  def open? = state == "open"
  def closed? = state == "closed"

  # Mirrors PreviewEnvironment#preview_url: derived, not stored, so the
  # base domain can change without touching persisted rows. Uses the
  # distinct "preview-panel-" prefix so PreviewProxyMiddleware can tell
  # panel requests apart from PreviewEnvironment's "preview-<preview_environment_id>" ones.
  #
  # scheme must match the embedding page's scheme (https app -> https panel
  # URL) or browsers block the iframe load as mixed active content.
  def preview_url(base_domain, scheme: "http") = "#{scheme}://preview-panel-#{id}.#{base_domain}"

  # Looks up an attached file by its stored relative path (e.g.
  # "index.html", "css/app.css"). Blank/root paths resolve to the
  # conventional entry point. Path lookup goes through blob metadata,
  # not ActiveStorage's filename attribute, because ActiveStorage
  # sanitizes "/" out of filenames (mirrors Workflow#visual_artifact_for's
  # metadata-keyed lookup).
  def file_for(relative_path)
    path = relative_path.to_s.delete_prefix("/").presence || DEFAULT_ENTRY_FILENAME
    files.find { |attachment| attachment.blob.metadata["relative_path"] == path }
  end

  # Replaces the full attached file set. update! calls through here so a
  # panel always reflects the latest upload rather than accumulating stale
  # files from earlier revisions.
  def replace_files!(files_by_path)
    files.purge
    files_by_path.each do |relative_path, content|
      io = content.respond_to?(:read) ? content : StringIO.new(content.to_s)
      files.attach(
        io: io,
        filename: relative_path.to_s,
        metadata: { "relative_path" => relative_path.to_s }
      )
    end
  end

  def broadcast_change!
    AppEvents.broadcast(
      user: chat_session.user,
      type: "updated",
      resource: "chat",
      id: chat_session_id,
      changed: [ "preview_panels" ],
      payload: broadcast_payload
    )
  end

  private

  def broadcast_payload
    {
      "id" => id,
      "title" => title,
      "state" => state,
      "file_count" => files.size
    }
  end
end
