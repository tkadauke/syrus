require "uri"

class Document < ApplicationRecord
  KINDS = %w[file google_doc pending_snapshot].freeze
  MAX_FILE_SIZE = 20.megabytes
  MAX_PREVIEW_SIZE = 500.kilobytes
  MAX_CONTENT_CACHE_SIZE = 64.kilobytes
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
  OFFICE_CONTENT_TYPE_PREFIX = "application/vnd.openxmlformats-officedocument.".freeze
  ALLOWED_CONTENT_TYPES = ACCEPTED_FILE_CONTENT_TYPES

  belongs_to :attachable, polymorphic: true
  belongs_to :user, optional: true
  has_one_attached :file, dependent: :purge

  before_validation :normalize_kind
  before_validation :fill_blank_title

  normalizes :google_doc_url, with: ->(url) { url.to_s.strip.presence }

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :title, presence: true
  validates :source_url, uniqueness: { scope: %i[attachable_type attachable_id] }, allow_blank: true
  validates :byte_size, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :file_document_has_valid_file
  validate :file_document_has_no_google_doc_fields
  validate :google_doc_has_url
  validate :google_doc_url_is_google_doc
  validate :google_doc_has_no_file
  validate :content_cache_within_limit
  validate :job_document_count_within_limit, on: :create

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def file?
    kind == "file"
  end

  def google_doc?
    kind == "google_doc"
  end

  def pending_snapshot?
    kind == "pending_snapshot"
  end

  def uploaded_file?
    file?
  end

  def google_doc_link?
    google_doc?
  end

  def attachment_type
    google_doc? ? "google_doc_link" : "uploaded_file"
  end

  def attachment_type=(value)
    self.kind = value.to_s == "google_doc_link" ? "google_doc" : "file"
  end

  def google_docs_url
    google_doc_url
  end

  def google_docs_url=(value)
    self.google_doc_url = value
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

    google_doc_url.to_s
  end

  def prompt_type
    return content_type if content_type.present?

    google_doc? ? "Google Doc URL" : "File"
  end

  private

  def normalize_kind
    self.kind = kind.to_s.strip
    self.kind = "file" if kind.blank?
  end

  def fill_blank_title
    self.title = title.to_s.strip
    self.title = filename if title.blank? && file?
    self.title = "Google Doc" if title.blank? && google_doc?
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

  def file_document_has_no_google_doc_fields
    return unless file?

    if google_doc_url.present?
      errors.add(:google_doc_url, :must_be_blank_for_file)
    end
    errors.add(:content_cache, :must_be_blank_for_file) if content_cache.present?
    errors.add(:content_cached_at, :must_be_blank_for_file) if content_cached_at.present?
  end

  def google_doc_has_url
    return unless google_doc?

    errors.add(:google_doc_url, :blank) if google_doc_url.blank?
  end

  def google_doc_url_is_google_doc
    return unless google_doc?
    return if google_doc_url.blank?

    uri = URI.parse(google_doc_url)
    unless uri.is_a?(URI::HTTPS) && uri.host.to_s == "docs.google.com"
      errors.add(:google_doc_url, :invalid_google_doc_url)
    end
  rescue URI::InvalidURIError
    errors.add(:google_doc_url, :invalid)
  end

  def google_doc_has_no_file
    return unless google_doc?

    errors.add(:file, :cannot_attach_to_google_doc) if file.attached?
  end

  def content_cache_within_limit
    return if content_cache.blank?
    return if content_cache.to_s.bytesize <= MAX_CONTENT_CACHE_SIZE

    errors.add(:content_cache, :content_cache_too_large, size: 64)
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
