module DesignDocs
  class DesignDocCollaborator < ApplicationRecord
    self.table_name = "design_doc_collaborators"

    ROLES = %w[viewer editor].freeze

    belongs_to :design_doc, class_name: "DesignDocs::DesignDoc"
    belongs_to :user
    belongs_to :added_by_user, class_name: "User", optional: true

    validates :role, presence: true, inclusion: { in: ROLES }
    validates :user_id, uniqueness: { scope: :design_doc_id }
    validate :owner_is_not_explicit_collaborator

    after_commit :publish_design_doc_search_upsert, on: [ :create, :update ]
    after_destroy_commit :publish_design_doc_search_upsert

    private

    def owner_is_not_explicit_collaborator
      return if design_doc.nil? || user_id.blank?
      return if design_doc.owner_user_id != user_id

      errors.add(:user, "is already the owner")
    end

    def publish_design_doc_search_upsert
      Syrus::Events.publish("design_doc.upserted", design_doc_id: design_doc_id)
    end
  end
end
