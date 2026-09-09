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
  end
end
