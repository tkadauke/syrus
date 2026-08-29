module DesignDocs
  class DesignDocAnchor < ApplicationRecord
    self.table_name = "design_doc_anchors"

    belongs_to :design_doc, class_name: "DesignDocs::DesignDoc"
    belongs_to :design_doc_version, class_name: "DesignDocs::DesignDocVersion", optional: true

    has_many :threads, class_name: "DesignDocs::DesignDocThread", dependent: :destroy
    has_many :suggestions, class_name: "DesignDocs::DesignDocSuggestion", dependent: :destroy

    before_validation :seed_anchor_key

    validates :anchor_key, presence: true, uniqueness: { scope: :design_doc_id }
    validates :start_offset, :end_offset, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :end_offset_not_before_start_offset
    validate :version_belongs_to_doc

    def hidden_marker
      "<!-- syrus-design-doc-anchor:#{anchor_key} -->"
    end

    private

    def seed_anchor_key
      self.anchor_key = SecureRandom.uuid if anchor_key.blank?
    end

    def end_offset_not_before_start_offset
      return if start_offset.blank? || end_offset.blank?
      return if end_offset >= start_offset

      errors.add(:end_offset, "must be greater than or equal to start offset")
    end

    def version_belongs_to_doc
      return if design_doc_version.nil? || design_doc.nil?
      return if design_doc_version.design_doc_id == design_doc_id

      errors.add(:design_doc_version, "must belong to the same design doc")
    end
  end
end
