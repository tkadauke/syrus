module DesignDocs
  # What used to be six associations injected onto User, Repository and
  # ChatSession at boot. None of them was ever read: both core call sites that
  # look at design docs start from `DesignDocs::DesignDoc` and use this
  # plugin's own `has_many :design_doc_repositories`, not the injected one. So
  # the injections only ever carried their `dependent:` behaviour, which is
  # what this replaces.
  #
  # Registered without a `plugin:` scope: disabling this plugin hides the
  # design docs UI, it does not delete the documents, and they still have to be
  # dealt with when their owner, repository or origin chat goes.
  module DataCleanup
    def self.install!
      Syrus::Installer.define("design_docs:data_cleanup") do |scope|
        scope.effect("user documents") do
          Syrus::DataCleanup.register("User", "design_docs.owned_documents") do |user|
            DesignDocs::DesignDoc.where(owner_user_id: user.id).find_each(&:destroy)
            DesignDocs::DesignDocCollaborator.where(user_id: user.id).find_each(&:destroy)
          end
        end

        scope.effect("repository links") do
          Syrus::DataCleanup.register("Repository", "design_docs.repository_links") do |repository|
            DesignDocs::DesignDocRepository.where(repository_id: repository.id).find_each(&:destroy)
          end
        end

        # Nullify, not destroy: a document that happened to originate in a
        # chat outlives that chat. This mirrors the `dependent: :nullify` the
        # injected association carried.
        scope.effect("origin chat back-references") do
          Syrus::DataCleanup.register("ChatSession", "design_docs.origin_chat") do |chat_session|
            DesignDocs::DesignDoc.where(origin_chat_session_id: chat_session.id)
                                 .update_all(origin_chat_session_id: nil)
          end
        end
      end
    end
  end
end
