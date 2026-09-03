module DesignDocs
  class CommentBroadcaster
    def self.call(...)
      new(...).call
    end

    def initialize(design_doc:, changed:)
      @design_doc = design_doc
      @changed = changed
    end

    def call
      recipients.find_each do |recipient|
        AppEvents.broadcast(
          user: recipient,
          type: "design_doc.updated",
          resource: "design_doc",
          id: design_doc.id,
          changed: changed
        )
      end
    end

    private

    attr_reader :design_doc, :changed

    def recipients
      User.where(id: recipient_ids)
    end

    def recipient_ids
      ids = [ design_doc.owner_user_id ]
      ids.concat(design_doc.collaborators.pluck(:user_id))
      ids.concat(public_repository_member_ids) if design_doc.public?
      ids.compact.uniq
    end

    def public_repository_member_ids
      repository_ids = design_doc.design_doc_repositories.select(:repository_id)
      direct_member_ids = RepositoryMembership.where(repository_id: repository_ids).select(:user_id)
      team_ids = TeamRepository.where(repository_id: repository_ids).select(:team_id)
      team_member_ids = TeamMembership.where(team_id: team_ids).select(:user_id)

      User.where(id: direct_member_ids).or(User.where(id: team_member_ids)).pluck(:id)
    end
  end
end
