module PendingActions
  class CreateRepoDocument < Base
    action_key "create_repo_document"

    def execute
      repo = action_user_repository
      document = repo.repository_documents.new(
        user: user,
        kind: "file",
        title: payload.fetch("title").to_s
      )
      document.file.attach(
        io: StringIO.new(payload.fetch("body").to_s),
        filename: document_filename(document.title),
        content_type: "text/markdown"
      )
      document.save!
      document
    end

    def validate_payload(errors)
      errors.add(:payload, "repository_id is required") unless payload["repository_id"].present?
      errors.add(:payload, "title is required") if payload["title"].to_s.strip.blank?
      errors.add(:payload, "body is required") if payload["body"].to_s.blank?
    end

    def action_detail
      "title: #{payload["title"]}"
    end
  end
end
