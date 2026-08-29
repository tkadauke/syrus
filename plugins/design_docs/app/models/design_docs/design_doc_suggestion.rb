module DesignDocs
  class DesignDocSuggestion < ApplicationRecord
    self.table_name = "design_doc_suggestions"

    STATES = %w[pending accepted rejected].freeze
    SUGGESTER_KINDS = %w[user agent system].freeze

    belongs_to :design_doc, class_name: "DesignDocs::DesignDoc"
    belongs_to :anchor, class_name: "DesignDocs::DesignDocAnchor", foreign_key: :design_doc_anchor_id
    belongs_to :thread, class_name: "DesignDocs::DesignDocThread", foreign_key: :design_doc_thread_id, optional: true
    belongs_to :suggested_by_user, class_name: "User", optional: true
    belongs_to :reviewed_by_user, class_name: "User", optional: true

    before_validation :normalize_markdown_fields

    validates :state, presence: true, inclusion: { in: STATES }
    validates :suggested_by_kind, presence: true, inclusion: { in: SUGGESTER_KINDS }
    validates :original_markdown, :suggested_markdown, presence: true
    validates :suggested_by_user, presence: true, if: :user_suggester?
    validate :anchor_belongs_to_doc
    validate :thread_belongs_to_doc
    validate :review_metadata_matches_state

    def user_suggester?
      suggested_by_kind == "user"
    end

    private

    def normalize_markdown_fields
      self.original_markdown = original_markdown.to_s
      self.suggested_markdown = suggested_markdown.to_s
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

    def review_metadata_matches_state
      return if state != "pending"

      errors.add(:reviewed_at, "must be blank for pending suggestions") if reviewed_at.present?
      errors.add(:reviewed_by_user, "must be blank for pending suggestions") if reviewed_by_user.present?
    end
  end
end
