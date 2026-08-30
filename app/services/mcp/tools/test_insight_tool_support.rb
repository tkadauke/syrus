module Mcp::Tools
  module TestInsightToolSupport
    private

    def current_context(server_context)
      McpToolContext.from_server_context(server_context)
    end

    def repository_for(context, repository: nil, repository_id: nil)
      return context.repository if context.run? && repository.blank? && repository_id.blank?

      scope = repository_scope_for(context)
      if repository_id.present?
        scope.find(repository_id)
      else
        owner, name = repository.to_s.strip.split("/", 2)
        raise ActiveRecord::RecordNotFound if owner.blank? || name.blank?

        scope.find_by!(owner: owner, name: name)
      end
    end

    def repository_scope_for(context)
      base = context.user.admin? ? Repository.all : Repository.accessible_to(context.user)
      base = base.where(id: context.repository.id) if context.run? && context.repository
      base
    end

    def normalize_filter(value)
      value.to_s.presence
    end

    def normalize_filters(filters, lookback)
      normalized = (filters || {}).to_h
      normalized[:lookback] = lookback if lookback.present?
      normalized
    end

    def truthy?(value, default: false)
      return default if value.nil?
      return value if value == true || value == false

      return default if value.respond_to?(:blank?) && value.blank?

      !%w[false 0 no off].include?(value.to_s.downcase)
    end
  end
end
