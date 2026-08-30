class PreviewPanel < ApplicationRecord
  STATES = %w[ open closed ].freeze
  VISIBILITIES = %w[ private public ].freeze
  DEFAULT_ENTRY_FILENAME = "index.html"

  belongs_to :chat_session
  has_many :preview_panel_versions, dependent: :destroy

  validates :title, presence: true
  validates :state, presence: true, inclusion: { in: STATES }
  validates :visibility, presence: true, inclusion: { in: VISIBILITIES }

  def open? = state == "open"
  def closed? = state == "closed"

  # "public" is the explicit opt-in; anything else (including the "private"
  # default) requires PreviewProxyMiddleware's token/cookie check.
  def public? = visibility == "public"
  def private? = visibility == "private"

  # Mirrors PreviewEnvironment#preview_url: derived, not stored, so the
  # base domain can change without touching persisted rows. Uses the
  # distinct "preview-panel-" prefix so PreviewProxyMiddleware can tell
  # panel requests apart from PreviewEnvironment's "preview-<preview_environment_id>" ones.
  #
  # scheme must match the embedding page's scheme (https app -> https panel
  # URL) or browsers block the iframe load as mixed active content.
  def preview_url(base_domain, scheme: "http") = "#{scheme}://preview-panel-#{id}.#{base_domain}"

  # preview_panel_versions is newest-first (PreviewPanelVersion's default
  # scope), so the first row is always the latest published snapshot.
  def current_version
    preview_panel_versions.first
  end

  # Looks up an attached file by its stored relative path (e.g.
  # "index.html", "css/app.css") within a version, defaulting to the
  # current (latest) one.
  def file_for(relative_path, version: nil)
    (version || current_version)&.file_for(relative_path)
  end

  # Creates a new PreviewPanelVersion snapshot from the given files and
  # leaves prior versions intact, so old versions stay servable after a
  # later show_preview call republishes the panel.
  def create_version!(files_by_path = nil, entry_file: DEFAULT_ENTRY_FILENAME, **keyword_files_by_path)
    files_by_path = (files_by_path || {}).merge(keyword_files_by_path)
    version = preview_panel_versions.create!(entry_file: entry_file.to_s.presence || DEFAULT_ENTRY_FILENAME)
    files_by_path.each do |relative_path, content|
      io = content.respond_to?(:read) ? content : StringIO.new(content.to_s)
      version.files.attach(
        io: io,
        filename: relative_path.to_s,
        metadata: { "relative_path" => relative_path.to_s }
      )
    end
    version
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
      "visibility" => visibility,
      "file_count" => current_version&.files&.size || 0,
      "entry_file" => current_version&.entry_file || DEFAULT_ENTRY_FILENAME
    }
  end
end
