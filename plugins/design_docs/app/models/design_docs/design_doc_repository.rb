module DesignDocs
  class DesignDocRepository < ApplicationRecord
    self.table_name = "design_doc_repositories"

    belongs_to :design_doc, class_name: "DesignDocs::DesignDoc"
    belongs_to :repository

    validates :repository_id, uniqueness: { scope: :design_doc_id }
  end
end
