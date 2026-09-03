module DesignDocs
  class CommentBroadcaster
    def self.call(...)
      new(...).call
    end

    def initialize(result:)
      @result = result
      @design_doc = result.design_doc
    end

    def call
      recipients.find_each do |user|
        AppEvents.broadcast(
          user: user,
          type: "design_doc.comment_created",
          resource: "design_doc",
          id: design_doc.id,
          changed: [ "comments", "threads" ],
          payload: {
            thread: DesignDocs::Serializer.thread(result.thread),
            comment: DesignDocs::Serializer.comment(result.comment)
          }
        )
      end
    end

    private

    attr_reader :result, :design_doc

    def recipients
      User.where(id: recipient_ids).distinct
    end

    def recipient_ids
      [
        design_doc.owner_user_id,
        collaborator_user_ids,
        public_repository_member_ids,
        admin_user_ids
      ].flatten.compact
    end

    def collaborator_user_ids
      design_doc.collaborators.pluck(:user_id)
    end

    def public_repository_member_ids
      return [] unless design_doc.public?

      RepositoryMembership.where(repository_id: design_doc.repositories.select(:id)).pluck(:user_id)
    end

    def admin_user_ids
      User.admin.pluck(:id)
    end
  end
end
