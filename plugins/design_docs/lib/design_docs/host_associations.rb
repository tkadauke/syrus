module DesignDocs
  module HostAssociations
    def self.apply!
      apply_user_associations
      apply_repository_associations
      apply_chat_session_associations
    end

    def self.apply_user_associations
      return if User.reflect_on_association(:owned_design_docs)

      User.has_many :owned_design_docs,
                    class_name: "DesignDocs::DesignDoc",
                    foreign_key: :owner_user_id,
                    dependent: :destroy,
                    inverse_of: :owner_user
      User.has_many :design_doc_collaborations,
                    class_name: "DesignDocs::DesignDocCollaborator",
                    dependent: :destroy
      User.has_many :collaborative_design_docs,
                    through: :design_doc_collaborations,
                    source: :design_doc
    end

    def self.apply_repository_associations
      return if Repository.reflect_on_association(:design_doc_repositories)

      Repository.has_many :design_doc_repositories,
                          class_name: "DesignDocs::DesignDocRepository",
                          dependent: :destroy
      Repository.has_many :design_docs, through: :design_doc_repositories
    end

    def self.apply_chat_session_associations
      return if ChatSession.reflect_on_association(:originated_design_docs)

      ChatSession.has_many :originated_design_docs,
                           class_name: "DesignDocs::DesignDoc",
                           foreign_key: :origin_chat_session_id,
                           dependent: :nullify,
                           inverse_of: :origin_chat_session
    end
  end
end
