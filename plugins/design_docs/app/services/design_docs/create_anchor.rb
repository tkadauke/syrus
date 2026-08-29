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
      inserted = AnchorMarkers.insert(
        markdown: design_doc.markdown,
        marker_id: marker_id,
        start_offset: start_offset,
        end_offset: end_offset,
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
        selected_markdown: selected_markdown(inserted),
        selected_text: selected_markdown(inserted),
        prefix_context: inserted.prefix_context,
        suffix_context: inserted.suffix_context,
        status: "active"
      )

      Result.new(anchor: anchor, version: version)
    end

    private

    attr_reader :design_doc, :user, :attributes, :actor_kind

    def start_offset
      attributes[:start_offset].presence&.to_i || 0
    end

    def end_offset
      attributes[:end_offset].presence&.to_i || start_offset
    end

    def selected_markdown(inserted)
      attributes[:selected_markdown].presence || attributes[:selected_text].presence || inserted.selected_markdown
    end

    def default_anchor_kind
      start_offset == end_offset ? "point" : "range"
    end

    def next_version_number
      design_doc.versions.maximum(:version_number).to_i + 1
    end
  end
end
