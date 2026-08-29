class DesignDocRepository < ApplicationRecord
  belongs_to :design_doc
  belongs_to :repository

  validates :repository_id, uniqueness: { scope: :design_doc_id }
end
