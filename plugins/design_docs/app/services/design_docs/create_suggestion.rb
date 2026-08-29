module DesignDocs
  class CreateSuggestion
    Result = Data.define(:design_doc, :anchor, :suggestion, :version)

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
      raise Pundit::NotAuthorizedError unless DesignDocPolicy.new(user, design_doc).suggest?

      DesignDoc.transaction do
        base_version = design_doc.current_version
        anchor_result = CreateAnchor.call(
          design_doc: design_doc,
          user: user,
          attributes: anchor_attributes,
          actor_kind: actor_kind
        )
        suggestion = design_doc.suggestions.create!(
          anchor: anchor_result.anchor,
          thread: suggestion_thread(anchor_result.anchor),
          base_version: base_version,
          suggested_by_kind: actor_kind,
          suggested_by_user: actor_kind == "user" ? user : nil,
          original_markdown: original_markdown(anchor_result.anchor),
          suggested_markdown: proposed_markdown,
          proposed_markdown: proposed_markdown,
          change_type: attributes[:change_type].presence || "replace",
          change_summary: attributes[:change_summary].presence,
          provenance: provenance(base_version)
        )

        Result.new(design_doc: design_doc.reload, anchor: anchor_result.anchor, suggestion: suggestion, version: anchor_result.version)
      end
    end

    private

    attr_reader :design_doc, :user, :attributes, :actor_kind

    def anchor_attributes
      attributes.slice(:start_offset, :end_offset, :selected_markdown, :selected_text, :anchor_kind)
        .merge(change_summary: "Add suggestion anchor")
    end

    def suggestion_thread(anchor)
      return nil if attributes[:thread_id].blank?

      design_doc.threads.find(attributes[:thread_id])
    end

    def original_markdown(anchor)
      attributes[:original_markdown].presence || attributes[:selected_markdown].presence || attributes[:selected_text].presence || anchor.selected_text.to_s
    end

    def proposed_markdown
      attributes[:proposed_markdown].presence || attributes[:suggested_markdown].presence || attributes[:markdown].to_s
    end

    def provenance(base_version)
      {
        "suggested_at" => Time.current.iso8601,
        "suggested_by_user_id" => actor_kind == "user" ? user&.id : nil,
        "actor_kind" => actor_kind,
        "base_version_id" => base_version&.id,
        "run_id" => attributes[:run_id].presence,
        "workflow_id" => attributes[:workflow_id].presence,
        "chat_message_id" => attributes[:chat_message_id].presence
      }.compact
    end
  end
end
