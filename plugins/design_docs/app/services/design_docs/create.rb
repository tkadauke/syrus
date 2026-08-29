module DesignDocs
  class Create
    Result = Data.define(:design_doc)

    def self.call(...)
      new(...).call
    end

    def initialize(user:, attributes:)
      @user = user
      @attributes = attributes
    end

    def call
      DesignDoc.transaction do
        design_doc = DesignDoc.create!(
          owner_user: user,
          title: attributes[:title].to_s,
          markdown: attributes[:markdown].to_s,
          visibility: attributes[:visibility].presence || "private",
          state: attributes[:state].presence || "draft",
          origin_chat_session: origin_chat_session
        )

        sync_repositories!(design_doc)
        sync_collaborators!(design_doc)
        version = design_doc.versions.create!(
          markdown: design_doc.markdown,
          version_number: 1,
          actor_kind: "user",
          actor_user: user,
          change_summary: attributes[:change_summary].presence
        )
        design_doc.update!(current_version: version)

        Result.new(design_doc: design_doc.reload)
      end
    end

    private

    attr_reader :user, :attributes

    def origin_chat_session
      id = attributes[:origin_chat_session_id].presence
      return nil unless id

      user.chat_sessions.find(id)
    end

    def sync_repositories!(design_doc)
      ids = Array(attributes[:repository_ids]).filter_map(&:presence).map(&:to_i).uniq
      return if ids.empty?

      repositories = Repository.accessible_to(user).where(id: ids).to_a
      raise ActiveRecord::RecordNotFound, "Repository not found" if repositories.size != ids.size

      design_doc.repositories = repositories
    end

    def sync_collaborators!(design_doc)
      ids = Array(attributes[:collaborator_user_ids]).filter_map(&:presence).map(&:to_i).uniq - [ user.id ]
      users = User.where(id: ids).to_a
      raise ActiveRecord::RecordNotFound, "User not found" if users.size != ids.size

      users.each do |collaborator|
        design_doc.collaborators.create!(user: collaborator, role: "editor", added_by_user: user)
      end
    end
  end
end
