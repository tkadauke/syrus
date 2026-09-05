# A narrated screen recording of the user testing their app, attached to a
# chat. Gemini extracts a structured account of everything shown/narrated
# (issues, summary, open questions); the analysis is then injected into the
# chat as a turn so the EXISTING chat agent can ask follow-ups or propose an
# Epic through the normal proposal machinery. Gemini is the eyes; the chat
# agent stays the brain.
class VideoWalkthroughs::Walkthrough < ApplicationRecord
  self.table_name = "video_walkthroughs"

  STATES = %w[uploaded analyzing analyzed failed].freeze
  # MediaRecorder produces webm; drag-ins are commonly mp4/mov. All are
  # Gemini-supported natively, so no transcoding anywhere.
  ALLOWED_CONTENT_TYPES = %w[video/webm video/mp4 video/quicktime].freeze
  # 2 GB is Gemini's hard per-file cap; 500 MB keeps uploads snappy and is
  # ~25 minutes at the recorder profile — far beyond the duration gate.
  MAX_FILE_SIZE = 500.megabytes
  # Recorder + drag-in duration gate. Recordings at default media resolution
  # cost ~300 tokens/sec; the analysis job switches Gemini to low resolution
  # beyond 12 minutes so even a full 15-minute video fits free-tier windows.
  MAX_DURATION_SECONDS = 15 * 60
  # The Gemini Files API retains an uploaded file for ~48h. Within that window
  # a range of the SAME upload can be re-analyzed (segment "zoom in") with no
  # re-upload; past it, the segment tool re-uploads the stored blob if present.
  GEMINI_FILE_RETENTION = 48.hours

  belongs_to :chat_session
  belongs_to :user
  has_one_attached :file, dependent: :purge

  attribute :state, :string, default: "uploaded"

  validates :state, inclusion: { in: STATES }
  validates :content_type, inclusion: {
    in: ALLOWED_CONTENT_TYPES,
    message: "must be a webm, mp4, or QuickTime video"
  }
  validates :byte_size, numericality: {
    only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_FILE_SIZE
  }
  validates :duration_seconds, numericality: {
    only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_DURATION_SECONDS
  }, allow_nil: true
  # Only required at creation — the prune job purges the blob from settled
  # rows after a retention window, and re-delivery retries (analysis already
  # present) don't need the video, so a later update must not demand it.
  validate :file_attached, on: :create

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  STATES.each do |name|
    define_method("#{name}?") { state == name }
  end

  def analysis_summary
    analysis&.dig("summary").to_s
  end

  def analysis_transcript
    Array(analysis&.dig("transcript"))
  end

  def analysis_sections
    Array(analysis&.dig("sections"))
  end

  def analysis_issues
    Array(analysis&.dig("issues"))
  end

  def analysis_open_questions
    Array(analysis&.dig("open_questions"))
  end

  # True when the Gemini Files API upload is still within its ~48h retention
  # window, so a segment re-analysis can reference the same file_uri without
  # re-uploading. The segment tool falls back to re-uploading the stored blob
  # when this is false.
  def gemini_file_fresh?
    gemini_file_uri.present? && gemini_file_active_at.present? &&
      gemini_file_active_at > GEMINI_FILE_RETENTION.ago
  end

  # MIME type to send as fileData.mimeType when re-referencing the RETAINED
  # Gemini upload. The bytes uploaded to Gemini can differ from the row's
  # current content_type: the analysis job transcodes the stored blob to mp4
  # AFTER uploading the (pre-transcode) original, so content_type drifts to
  # video/mp4 while the retained upload is still the webm. gemini_file_content_type
  # is stamped with the uploaded mime at upload time; fall back to content_type
  # for rows recorded before that column existed.
  def gemini_upload_content_type
    gemini_file_content_type.presence || content_type
  end

  def display_title
    title.presence || "Walkthrough video"
  end

  private

  def file_attached
    errors.add(:file, "must be attached") unless file.attached?
  end
end
