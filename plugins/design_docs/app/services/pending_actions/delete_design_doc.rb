module PendingActions
  class DeleteDesignDoc < Base
    action_key "delete_design_doc"

    def execute
      design_doc = DesignDocs::DesignDoc.visible_to(user).find(payload.fetch("design_doc_id"))
      result = DesignDocs::Archive.call(
        design_doc: design_doc,
        user: user,
        audit_reason: reason.presence || payload["confirmation_reason"],
        pending_action: action
      )
      result.design_doc
    end

    def execution_label
      "Archiving design doc..."
    end

    def validate_payload(errors)
      errors.add(:payload, "design_doc_id is required") unless payload["design_doc_id"].present?
      errors.add(:payload, "doc_ref is required") unless payload["doc_ref"].present?
      errors.add(:payload, "title is required") unless payload["title"].present?
    end

    def action_detail
      "#{payload["doc_ref"]}: #{payload["title"]}"
    end

    def presentation_label
      "Archive #{payload["doc_ref"].presence || "DOC-#{payload["design_doc_id"]}"}"
    end

    def presentation_detail
      [
        payload["title"].presence,
        payload["confirmation_reason"].presence
      ].compact.join("\n").presence
    end
  end
end
