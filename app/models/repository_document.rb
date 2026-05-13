class RepositoryDocument < ApplicationRecord
  KINDS = %w[ file google_doc ].freeze
  MAX_FILE_SIZE = 20.megabytes
  MAX_CONTENT_CACHE_SIZE = 64.kilobytes
  ACCEPTED_FILE_CONTENT_TYPES = [
    "text/plain",
    "text/markdown",
    "application/pdf",
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "image/svg+xml"
  ].freeze
  OFFICE_CONTENT_TYPE_PREFIX = "application/vnd.openxmlformats-officedocument.".freeze

  belongs_to :repository
  belongs_to :user
  has_one_attached :file, dependent: :purge

  before_validation :normalize_kind
  before_validation :fill_blank_title

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :title, presence: true
  validate :file_document_has_valid_file
  validate :file_document_has_no_google_doc_fields
  validate :google_doc_has_url
  validate :google_doc_has_no_file
  validate :content_cache_within_limit

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def file?
    kind == "file"
  end

  def google_doc?
    kind == "google_doc"
  end

  def content_type
    file.attached? ? file.content_type : nil
  end

  private

  def normalize_kind
    self.kind = kind.to_s.strip
  end

  def fill_blank_title
    self.title = title.to_s.strip
    self.title = file.filename.to_s if title.blank? && file.attached?
    self.title = "Google Doc" if title.blank? && google_doc?
  end

  def file_document_has_valid_file
    return unless file?

    unless file.attached?
      errors.add(:file, "must be attached")
      return
    end

    if file.byte_size > MAX_FILE_SIZE
      errors.add(:file, "must be 20 MB or smaller")
    end

    return if accepted_file_content_type?(file.content_type)

    errors.add(:file, "must be a supported text, PDF, Office, or image file")
  end

  def file_document_has_no_google_doc_fields
    return unless file?

    errors.add(:google_docs_url, "must be blank for file documents") if google_docs_url.present?
    errors.add(:content_cache, "must be blank for file documents") if content_cache.present?
    errors.add(:content_cached_at, "must be blank for file documents") if content_cached_at.present?
  end

  def google_doc_has_url
    return unless google_doc?

    errors.add(:google_docs_url, "can't be blank") if google_docs_url.blank?
  end

  def google_doc_has_no_file
    return unless google_doc?

    errors.add(:file, "can't be attached to a Google Doc link") if file.attached?
  end

  def content_cache_within_limit
    return if content_cache.blank?
    return if content_cache.to_s.bytesize <= MAX_CONTENT_CACHE_SIZE

    errors.add(:content_cache, "must be 64 KB or smaller")
  end

  def accepted_file_content_type?(content_type)
    content_type.in?(ACCEPTED_FILE_CONTENT_TYPES) ||
      content_type.to_s.start_with?(OFFICE_CONTENT_TYPE_PREFIX)
  end
end
