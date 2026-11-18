class Document < ApplicationRecord
  KINDS = %w[file pending_snapshot].freeze
  MAX_FILE_SIZE = 20.megabytes
  MAX_PREVIEW_SIZE = 500.kilobytes
  MAX_ATTACHMENTS_PER_JOB = 10
  ACCEPTED_FILE_CONTENT_TYPES = [
    "text/plain",
    "text/markdown",
    "text/x-markdown",
    "text/html",
    "text/css",
    "text/javascript",
    "application/pdf",
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "image/svg+xml"
  ].freeze
  ACCEPTED_IMAGE_CONTENT_TYPES = ACCEPTED_FILE_CONTENT_TYPES.grep(/\Aimage\//).freeze
  OFFICE_CONTENT_TYPE_PREFIX = "application/vnd.openxmlformats-officedocument.".freeze
  ALLOWED_CONTENT_TYPES = ACCEPTED_FILE_CONTENT_TYPES

  belongs_to :attachable, polymorphic: true
  belongs_to :user, optional: true
  has_one_attached :file, dependent: :purge

  before_validation :normalize_kind
  before_validation :fill_blank_title

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :title, presence: true
  validates :source_url, uniqueness: { scope: %i[attachable_type attachable_id] }, allow_blank: true
  validates :byte_size, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :file_document_has_valid_file
  validate :job_document_count_within_limit, on: :create

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def file?
    kind == "file"
  end

  def pending_snapshot?
    kind == "pending_snapshot"
  end

  def uploaded_file?
    file?
  end

  def attachment_type
    "uploaded_file"
  end

  def attachment_type=(_value)
    self.kind = "file"
  end

  def job
    attachable if attachable_type == "Job"
  end

  def job=(value)
    self.attachable = value
  end

  def repository
    attachable if attachable_type == "Repository"
  end

  def repository=(value)
    self.attachable = value
  end

  def content_type
    self[:content_type].presence || (file.attached? ? file.blob.content_type.to_s : nil)
  end

  def byte_size
    self[:byte_size].presence || (file.attached? ? file.blob.byte_size : nil)
  end

  def filename
    self[:filename].presence || (file.attached? ? file.filename.to_s : nil)
  end

  def display_name
    return filename if filename.present?
    return title if title.present?

    ""
  end

  def prompt_type
    return content_type if content_type.present?

    "File"
  end

  private

  def normalize_kind
    self.kind = kind.to_s.strip
    self.kind = "file" if kind.blank?
  end

  def fill_blank_title
    self.title = title.to_s.strip
    self.title = filename if title.blank? && file?
    self.title = "Whiteboard Snapshot" if title.blank? && pending_snapshot?
  end

  def file_document_has_valid_file
    return unless file?

    unless file.attached?
      errors.add(:file, :must_be_attached)
      return
    end

    errors.add(:file, :file_too_large, size: 20) if file.blob.byte_size > MAX_FILE_SIZE
    return if accepted_file_content_type?(file.blob.content_type)

    errors.add(:file, :unsupported_file_type)
  end

  def job_document_count_within_limit
    return unless attachable_type == "Job" && attachable
    return if attachable.documents.count < MAX_ATTACHMENTS_PER_JOB

    errors.add(:base, :too_many_job_attachments, count: MAX_ATTACHMENTS_PER_JOB)
  end

  def accepted_file_content_type?(content_type)
    content_type.in?(ACCEPTED_FILE_CONTENT_TYPES) ||
      content_type.to_s.start_with?(OFFICE_CONTENT_TYPE_PREFIX)
  end
end
