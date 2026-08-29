class DesignDocSuggestion < ApplicationRecord
  STATES = %w[pending accepted rejected stale conflict].freeze
  SUGGESTER_KINDS = %w[user agent system].freeze
  CHANGE_TYPES = %w[replace].freeze

  belongs_to :design_doc
  belongs_to :anchor, class_name: "DesignDocAnchor", foreign_key: :design_doc_anchor_id
  belongs_to :thread, class_name: "DesignDocThread", foreign_key: :design_doc_thread_id, optional: true
  belongs_to :suggested_by_user, class_name: "User", optional: true
  belongs_to :reviewed_by_user, class_name: "User", optional: true
  belongs_to :base_version, class_name: "DesignDocVersion", optional: true

  before_validation :normalize_markdown_fields

  validates :state, presence: true, inclusion: { in: STATES }
  validates :suggested_by_kind, presence: true, inclusion: { in: SUGGESTER_KINDS }
  validates :change_type, presence: true, inclusion: { in: CHANGE_TYPES }
  validates :original_markdown, :suggested_markdown, :proposed_markdown, presence: true
  validates :suggested_by_user, presence: true, if: :user_suggester?
  validate :anchor_belongs_to_doc
  validate :thread_belongs_to_doc
  validate :base_version_belongs_to_doc
  validate :review_metadata_matches_state

  def user_suggester?
    suggested_by_kind == "user"
  end

  def proposed_markdown_value
    proposed_markdown.presence || suggested_markdown
  end

  private

  def normalize_markdown_fields
    self.original_markdown = original_markdown.to_s
    self.proposed_markdown = proposed_markdown.presence || suggested_markdown
    self.suggested_markdown = suggested_markdown.presence || proposed_markdown
    self.provenance = (provenance || {}).merge("suggested_at" => created_at&.iso8601 || Time.current.iso8601)
  end

  def anchor_belongs_to_doc
    return if anchor.nil? || design_doc.nil?
    return if anchor.design_doc_id == design_doc_id

    errors.add(:anchor, "must belong to the same design doc")
  end

  def thread_belongs_to_doc
    return if thread.nil? || design_doc.nil?
    return if thread.design_doc_id == design_doc_id

    errors.add(:thread, "must belong to the same design doc")
  end

  def base_version_belongs_to_doc
    return if base_version.nil? || design_doc.nil?
    return if base_version.design_doc_id == design_doc_id

    errors.add(:base_version, "must belong to the same design doc")
  end

  def review_metadata_matches_state
    return if state != "pending"

    errors.add(:reviewed_at, "must be blank for pending suggestions") if reviewed_at.present?
    errors.add(:reviewed_by_user, "must be blank for pending suggestions") if reviewed_by_user.present?
  end
end
