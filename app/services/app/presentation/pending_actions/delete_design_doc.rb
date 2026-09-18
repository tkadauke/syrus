module App
  module Presentation
    module PendingActions
      class DeleteDesignDoc < Base
        action_key "delete_design_doc"

        def label
          "Archive #{payload['doc_ref'].presence || "DOC-#{payload['design_doc_id']}"}"
        end

        def detail
          [
            payload["title"].presence,
            payload["confirmation_reason"].presence
          ].compact.join("\n").presence
        end
      end
    end
  end
end
