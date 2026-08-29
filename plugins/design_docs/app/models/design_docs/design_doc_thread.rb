module DesignDocs
  class DesignDocThread < ApplicationRecord
    self.table_name = "design_doc_threads"

    STATES = %w[open resolved].freeze

    belongs_to :design_doc, class_name: "DesignDocs::DesignDoc"
    belongs_to :anchor, class_name: "DesignDocs::DesignDocAnchor", foreign_key: :design_doc_anchor_id
    belongs_to :opened_by_user, class_name: "User", optional: true
    belongs_to :resolved_by_user, class_name: "User", optional: true

    has_many :comments, class_name: "DesignDocs::DesignDocComment", dependent: :destroy
    has_many :suggestions, class_name: "DesignDocs::DesignDocSuggestion", dependent: :nullify

    validates :state, presence: true, inclusion: { in: STATES }
    validate :anchor_belongs_to_doc
    validate :resolved_metadata_matches_state

    private

    def anchor_belongs_to_doc
      return if anchor.nil? || design_doc.nil?
      return if anchor.design_doc_id == design_doc_id

      errors.add(:anchor, "must belong to the same design doc")
    end

    def resolved_metadata_matches_state
      return unless state == "open"

      errors.add(:resolved_at, "must be blank for open threads") if resolved_at.present?
      errors.add(:resolved_by_user, "must be blank for open threads") if resolved_by_user.present?
    end
  end
end
