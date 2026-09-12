module DesignDocs
  class DesignDocRepository < ApplicationRecord
    self.table_name = "design_doc_repositories"

    belongs_to :design_doc, class_name: "DesignDocs::DesignDoc"
    belongs_to :repository

    validates :repository_id, uniqueness: { scope: :design_doc_id }

    after_commit :publish_design_doc_search_upsert, on: [ :create, :update ]
    after_destroy_commit :publish_design_doc_search_upsert

    private

    def publish_design_doc_search_upsert
      Syrus::Events.publish("design_doc.upserted", design_doc_id: design_doc_id)
    end
  end
end
