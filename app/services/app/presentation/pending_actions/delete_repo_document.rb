module App
  module Presentation
    module PendingActions
      class DeleteRepoDocument < Base
        action_key "delete_repo_document"

        def label
          "Delete document #{payload['title'].to_s.presence || "##{payload['document_id']}"}"
        end
      end
    end
  end
end
