module DesignDocs
  class CreateAnchor
    Result = Data.define(:anchor, :version)

    def self.call(...)
      new(...).call
    end

    def initialize(design_doc:, user:, attributes:, actor_kind: "user")
      @design_doc = design_doc
      @user = user
      @attributes = attributes
      @actor_kind = actor_kind.to_s.presence || "user"
    end

    def call
      design_doc.lock!
      base_version = design_doc.current_version
      marker_id = SecureRandom.uuid
      anchor_kind = attributes[:anchor_kind].presence || default_anchor_kind
      resolved_range = resolve_range!(anchor_kind)
      inserted = AnchorMarkers.insert(
        markdown: design_doc.markdown,
        marker_id: marker_id,
        start_offset: resolved_range.start_offset,
        end_offset: resolved_range.end_offset,
        anchor_kind: anchor_kind
      )

      design_doc.markdown = inserted.markdown
      design_doc.save!
      version = design_doc.versions.create!(
        markdown: design_doc.markdown,
        version_number: next_version_number,
        actor_kind: actor_kind,
        actor_user: actor_kind == "user" ? user : nil,
        change_summary: attributes[:change_summary].presence || "Add inline anchor marker"
      )
      design_doc.update!(current_version: version)

      anchor = design_doc.anchors.create!(
        marker_id: marker_id,
        anchor_key: marker_id,
        anchor_kind: anchor_kind,
        design_doc_version: base_version,
        start_offset: inserted.start_offset,
        end_offset: inserted.end_offset,
        last_known_start_offset: inserted.start_offset,
        last_known_end_offset: inserted.end_offset,
        selected_markdown: inserted.selected_markdown,
        selected_text: inserted.selected_markdown,
        prefix_context: inserted.prefix_context,
        suffix_context: inserted.suffix_context,
        status: "active"
      )

      Result.new(anchor: anchor, version: version)
    end

    private

    ResolvedRange = Data.define(:start_offset, :end_offset)

    attr_reader :design_doc, :user, :attributes, :actor_kind

    def start_offset
      attributes[:start_offset].presence&.to_i || 0
    end

    def end_offset
      attributes[:end_offset].presence&.to_i || start_offset
    end

    def resolve_range!(anchor_kind)
      range = normalized_range
      expected = expected_selection
      return range if anchor_kind.to_s == "point" || expected.blank?

      visible = AnchorMarkers.strip(design_doc.markdown)
      return range if visible[range.start_offset...range.end_offset].to_s == expected

      matches = exact_selection_matches(visible, expected)
      return ResolvedRange.new(start_offset: matches.first, end_offset: matches.first + expected.length) if matches.one?

      anchor = design_doc.anchors.build(
        anchor_kind: anchor_kind,
        start_offset: range.start_offset,
        end_offset: range.end_offset,
        selected_markdown: expected,
        selected_text: expected
      )
      anchor.errors.add(:base, anchor_validation_message(matches))
      raise ActiveRecord::RecordInvalid.new(anchor)
    end

    def normalized_range
      visible_length = AnchorMarkers.strip(design_doc.markdown).length
      start_value = start_offset.clamp(0, visible_length)
      end_value = end_offset.clamp(0, visible_length)
      start_value, end_value = end_value, start_value if end_value < start_value

      ResolvedRange.new(start_offset: start_value, end_offset: end_value)
    end

    def expected_selection
      attributes[:selected_text].presence || attributes[:selected_markdown].presence
    end

    def exact_selection_matches(markdown, selection)
      matches = []
      offset = 0
      while (index = markdown.index(selection, offset))
        matches << index
        offset = index + 1
      end
      matches
    end

    def anchor_validation_message(matches)
      return "Selected text does not match the submitted anchor offsets and could not be found in the design doc." if matches.empty?

      "Selected text does not match the submitted anchor offsets and appears multiple times in the design doc."
    end

    def default_anchor_kind
      start_offset == end_offset ? "point" : "range"
    end

    def next_version_number
      design_doc.versions.maximum(:version_number).to_i + 1
    end
  end
end
