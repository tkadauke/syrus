module App
  module Presentation
    module PendingActions
      class CreateRepoDocument < Base
        action_key "create_repo_document"

        def label
          "Create document #{payload['title'].to_s.inspect}"
        end
      end
    end
  end
end
