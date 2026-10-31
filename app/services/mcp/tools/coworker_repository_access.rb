module Mcp::Tools
  class CoworkerRepositoryAccess
    ALL = "all".freeze

    def self.resolve(server_context:, repository_id: nil, slug: nil)
      context = McpToolContext.from_server_context(server_context)
      repository = find_repository(context, repository_id:, slug:)
      return Mcp::Tools.invalid("repository not found or is not accessible") unless repository
      return repository unless context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])

      scope = context.capability_scopes["code.read"]
      return Mcp::Tools.not_authorized unless scope == ALL || Array(scope).map(&:to_i).include?(repository.id)

      repository
    end

    def self.scope_options(user:)
      repositories = Repository.accessible_to(user).active.order(:owner, :name, :id).to_a
      [ ALL ] + repositories.map { |repository| [ repository.id ] }
    end

    def self.scope_label(value)
      return "All repositories you can read" if value == ALL

      repositories = Repository.where(id: Array(value).map(&:to_i)).order(:owner, :name, :id)
      repositories.map(&:slug).join(", ").presence || "No repositories"
    end

    def self.valid_scope?(value, user:)
      return true if value == ALL
      ids = Array(value)
      return false if ids.empty? || ids.any? { |id| id.to_s !~ /\A\d+\z/ }

      accessible_ids = Repository.accessible_to(user).active.where(id: ids.map(&:to_i)).pluck(:id)
      accessible_ids.sort == ids.map(&:to_i).uniq.sort
    end

    class << self
      private

      def find_repository(context, repository_id:, slug:)
        scope = Repository.accessible_to(context.user).active
        return scope.find_by(id: repository_id) if repository_id.present?

        candidate = slug.presence || context.repository&.slug
        return unless candidate

        owner, name = candidate.to_s.split("/", 2)
        return unless owner.present? && name.present?

        scope.find_by("LOWER(owner) = ? AND LOWER(name) = ?", owner.downcase, name.downcase)
      end
    end
  end
end
