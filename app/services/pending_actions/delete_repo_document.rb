module PendingActions
  class DeleteRepoDocument < Base
    action_key "delete_repo_document"

    def execute
      document = action_user_document
      progress!("Deleting repository document #{document.id}...")
      document.file.purge if document.file.attached?
      document.destroy!
      nil
    end

    def execution_label
      "Deleting repository document..."
    end

    def validate_payload(errors)
      errors.add(:payload, "document_id is required") unless payload["document_id"].present?
    end

    def action_detail
      "document_id: #{payload["document_id"]}"
    end
  end
end
