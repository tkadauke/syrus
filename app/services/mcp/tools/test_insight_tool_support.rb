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

    def job_for(context, job_id:)
      scope = context.user.admin? ? Job.all : Job.accessible_to(context.user)
      scope = scope.where(repository_id: context.repository.id) if context.run? && context.repository
      scope.find(normalize_numeric_ref(job_id, prefix: "job"))
    end

    def run_for(context, run_id:)
      scope = context.user.admin? ? Run.joins(:job) : Run.joins(job: :repository).merge(Job.accessible_to(context.user))
      scope = scope.where(jobs: { repository_id: context.repository.id }) if context.run? && context.repository
      scope.find(normalize_numeric_ref(run_id, prefix: "run"))
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

    def truthy?(value)
      return value if value == true || value == false

      !%w[false 0 no off].include?(value.to_s.downcase)
    end

    def normalize_numeric_ref(value, prefix:)
      ref = value.to_s.strip
      ref = ref[(prefix.length + 1)..] if ref.match?(/\A#{Regexp.escape(prefix)}-/i)
      Integer(ref)
    rescue ArgumentError, TypeError
      raise ActiveRecord::RecordNotFound
    end
  end
end
