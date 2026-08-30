module DesignDocs
  class DesignDocAnchor < ApplicationRecord
    self.table_name = "design_doc_anchors"

    ANCHOR_KINDS = %w[point range].freeze
    STATUSES = %w[active missing duplicated stale].freeze

    belongs_to :design_doc, class_name: "DesignDocs::DesignDoc"
    belongs_to :design_doc_version, class_name: "DesignDocs::DesignDocVersion", optional: true

    has_many :threads, class_name: "DesignDocs::DesignDocThread", dependent: :destroy
    has_many :suggestions, class_name: "DesignDocs::DesignDocSuggestion", dependent: :destroy

    before_validation :seed_anchor_key
    before_validation :sync_legacy_anchor_fields

    validates :anchor_key, presence: true, uniqueness: { scope: :design_doc_id }
    validates :marker_id, presence: true, uniqueness: { scope: :design_doc_id }
    validates :anchor_kind, presence: true, inclusion: { in: ANCHOR_KINDS }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :start_offset, :end_offset, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :last_known_start_offset, :last_known_end_offset, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
    validate :end_offset_not_before_start_offset
    validate :version_belongs_to_doc

    def hidden_marker
      if point?
        DesignDocs::AnchorMarkers.point_marker(marker_id)
      else
        "#{DesignDocs::AnchorMarkers.range_start_marker(marker_id)}#{DesignDocs::AnchorMarkers.range_end_marker(marker_id)}"
      end
    end

    def point?
      anchor_kind == "point"
    end

    def range?
      anchor_kind == "range"
    end

    private

    def seed_anchor_key
      self.marker_id = anchor_key.presence || SecureRandom.uuid if marker_id.blank?
      self.anchor_key = marker_id if anchor_key.blank?
    end

    def sync_legacy_anchor_fields
      self.anchor_key = marker_id if anchor_key.blank? && marker_id.present?
      self.marker_id = anchor_key if marker_id.blank? && anchor_key.present?
      self.selected_text = selected_markdown if selected_text.blank? && selected_markdown.present?
      self.selected_markdown = selected_text if selected_markdown.blank? && selected_text.present?
      self.last_known_start_offset = start_offset if last_known_start_offset.blank? && start_offset.present?
      self.last_known_end_offset = end_offset if last_known_end_offset.blank? && end_offset.present?
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
