require "uri"

class JobAttachment < ApplicationRecord
  MAX_ATTACHMENTS_PER_JOB = 10
  MAX_FILE_SIZE = 20.megabytes
  ALLOWED_CONTENT_TYPES = %w[
    image/png
    image/jpeg
    image/gif
    image/webp
    application/pdf
    text/plain
    text/markdown
    text/x-markdown
  ].freeze

  belongs_to :job
  has_one_attached :file

  ATTACHMENT_TYPES = {
    uploaded_file: "uploaded_file",
    google_doc_link: "google_doc_link"
  }.freeze

  enum :attachment_type, ATTACHMENT_TYPES, validate: true

  before_validation :default_attachment_type

  normalizes :google_doc_url, with: ->(url) { url.to_s.strip.presence }

  validates :job, presence: true
  validates :attachment_type, presence: true
  validates :source_url, uniqueness: { scope: :job_id }, allow_blank: true
  validates :byte_size, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :file_required_for_upload
  validate :google_doc_url_required_for_link
  validate :google_doc_url_is_google_doc
  validate :file_content_type_allowed
  validate :file_size_within_limit
  validate :job_attachment_count_within_limit, on: :create

  def display_name
    return filename if filename.present?
    return file.filename.to_s if uploaded_file? && file.attached?

    google_doc_url.to_s
  end

  def prompt_type
    return content_type if content_type.present?
    return file.blob.content_type.to_s if uploaded_file? && file.attached?

    "Google Doc URL"
  end

  private

  def default_attachment_type
    self.attachment_type ||= :uploaded_file
  end

  def file_required_for_upload
    return unless uploaded_file?
    return if file.attached?

    errors.add(:file, "must be attached")
  end

  def google_doc_url_required_for_link
    return unless google_doc_link?
    return if google_doc_url.present?

    errors.add(:google_doc_url, "can't be blank")
  end

  def google_doc_url_is_google_doc
    return unless google_doc_link?
    return if google_doc_url.blank?

    uri = URI.parse(google_doc_url)
    unless uri.is_a?(URI::HTTPS) && uri.host.to_s == "docs.google.com"
      errors.add(:google_doc_url, "must be a docs.google.com HTTPS URL")
    end
  rescue URI::InvalidURIError
    errors.add(:google_doc_url, "is invalid")
  end

  def file_content_type_allowed
    return unless uploaded_file? && file.attached?
    return if ALLOWED_CONTENT_TYPES.include?(file.blob.content_type)

    errors.add(:file, "must be a PNG, JPG, GIF, WebP, PDF, plain text, or Markdown file")
  end

  def file_size_within_limit
    return unless uploaded_file? && file.attached?
    return if file.blob.byte_size <= MAX_FILE_SIZE

    errors.add(:file, "must be 20 MB or smaller")
  end

  def job_attachment_count_within_limit
    return unless job
    return if job.job_attachments.count < MAX_ATTACHMENTS_PER_JOB

    errors.add(:base, "Jobs can have at most #{MAX_ATTACHMENTS_PER_JOB} attachments")
  end
end
