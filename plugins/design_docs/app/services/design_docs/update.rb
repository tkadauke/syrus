module DesignDocs
  class Update
    Result = Data.define(:design_doc, :version, :suggestion, :mode)

    def self.call(...)
      new(...).call
    end

    def initialize(design_doc:, user:, attributes:, actor_kind: "user")
      @design_doc = design_doc
      @user = user
      @attributes = attributes
      @actor_kind = actor_kind.to_s.presence || "user"
    end

    def call
      DesignDoc.transaction do
        design_doc.lock!

        if canonical_update?
          apply_canonical_update
        else
          create_suggestion
        end
      end
    end

    private

    attr_reader :design_doc, :user, :attributes, :actor_kind

    def canonical_update?
      actor_kind == "user" && DesignDocPolicy.new(user, design_doc).canonical_write?
    end

    def create_suggestion
      raise Pundit::NotAuthorizedError unless DesignDocPolicy.new(user, design_doc).suggest?

      candidate_markdown = attributes[:markdown].to_s
      if candidate_markdown.blank?
        design_doc.errors.add(:markdown, "can't be blank for suggestions")
        raise ActiveRecord::RecordInvalid.new(design_doc)
      end
      proposed_markdown = proposed_markdown_for_selection(candidate_markdown)

      result = CreateSuggestion.call(
        design_doc: design_doc,
        user: user,
        actor_kind: actor_kind,
        attributes: attributes.merge(
          proposed_markdown: proposed_markdown,
          original_markdown: selected_markdown,
          anchor_kind: "range"
        )
      )

      Result.new(design_doc: result.design_doc, version: result.version, suggestion: result.suggestion, mode: "suggestion")
    end

    def apply_canonical_update
      permitted = attributes.slice(:title, :visibility, :state)
      markdown_changed = attributes.key?(:markdown) && attributes[:markdown].to_s != design_doc.markdown
      permitted[:markdown] = attributes[:markdown].to_s if attributes.key?(:markdown)

      design_doc.assign_attributes(permitted)
      sync_repositories! if attributes.key?(:repository_ids)
      sync_collaborators! if attributes.key?(:collaborator_user_ids)
      design_doc.save!

      version = nil
      if markdown_changed
        version = design_doc.versions.create!(
          markdown: design_doc.markdown,
          version_number: next_version_number,
          actor_kind: "user",
          actor_user: user,
          change_summary: attributes[:change_summary].presence
        )
        design_doc.update!(current_version: version)
      end

      Result.new(design_doc: design_doc.reload, version: version, suggestion: nil, mode: "canonical")
    end

    def sync_repositories!
      ids = Array(attributes[:repository_ids]).filter_map(&:presence).map(&:to_i).uniq
      repositories = Repository.accessible_to(user).where(id: ids).to_a
      raise ActiveRecord::RecordNotFound, "Repository not found" if repositories.size != ids.size

      design_doc.repositories = repositories
    end

    def sync_collaborators!
      ids = Array(attributes[:collaborator_user_ids]).filter_map(&:presence).map(&:to_i).uniq - [ design_doc.owner_user_id ]
      users = User.where(id: ids).to_a
      raise ActiveRecord::RecordNotFound, "User not found" if users.size != ids.size

      design_doc.collaborators.where.not(user_id: ids).destroy_all
      ids.each do |id|
        design_doc.collaborators.find_or_create_by!(user_id: id) do |collaborator|
          collaborator.role = "editor"
          collaborator.added_by_user = user
        end
      end
    end

    def next_version_number
      design_doc.versions.maximum(:version_number).to_i + 1
    end

    def anchor_start_offset
      attributes[:start_offset].presence&.to_i || 0
    end

    def anchor_end_offset
      attributes[:end_offset].presence&.to_i || design_doc.markdown.length
    end

    def selected_markdown
      explicit = attributes[:selected_markdown]
      return explicit.to_s if explicit.present?

      AnchorMarkers.strip(design_doc.markdown)[anchor_start_offset...anchor_end_offset].to_s
    end

    def proposed_markdown_for_selection(candidate_markdown)
      rendered_markdown = AnchorMarkers.strip(design_doc.markdown)
      prefix = rendered_markdown[0...anchor_start_offset].to_s
      suffix = rendered_markdown[anchor_end_offset..].to_s
      return candidate_markdown unless candidate_markdown.start_with?(prefix)
      return candidate_markdown unless suffix.empty? || candidate_markdown.end_with?(suffix)

      proposed_end = suffix.empty? ? candidate_markdown.length : candidate_markdown.length - suffix.length
      candidate_markdown[prefix.length...proposed_end].to_s
    end
  end
end
