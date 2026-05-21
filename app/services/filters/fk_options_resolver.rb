module Filters
  class FkOptionsResolver
    LIMIT = 50
    FIELDS = %w[ repository_id epic_id parent_job_id job_id tags hostname ].freeze

    UnknownField = Class.new(ArgumentError)

    def initialize(user:)
      @user = user
    end

    def resolve(field:, q: nil, ids: nil, limit: LIMIT)
      field = field.to_s
      raise UnknownField, field unless FIELDS.include?(field)

      scope = send("#{field}_scope")
      if ids.present?
        scope = field == "hostname" ? scope.where(hostname: Array(ids).reject(&:blank?)) : scope.where(id: Array(ids).reject(&:blank?))
      end
      scope = apply_search(field, scope, q.to_s.strip) if ids.blank? && q.present?
      scope = apply_order(field, scope)
      scope = scope.limit(limit) if ids.blank? && limit
      scope.map { |record| option_for(field, record) }
    end

    private

    attr_reader :user

    def repository_id_scope
      user.repositories.active
    end

    def epic_id_scope
      user.epics.includes(:repository)
    end

    def parent_job_id_scope
      user.jobs.where.not(branch_name: nil)
    end

    def job_id_scope
      user.jobs
    end

    def tags_scope
      user.tags
    end

    def hostname_scope
      SpawnedProcess.where("started_at > ?", 24.hours.ago).where.not(hostname: [ nil, "" ]).select(:hostname).distinct
    end

    def apply_search(field, scope, query)
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"

      case field
      when "repository_id"
        scope.where("repositories.owner LIKE :pattern OR repositories.name LIKE :pattern", pattern:)
      when "epic_id"
        scope.where("epics.title LIKE ?", pattern)
      when "parent_job_id", "job_id"
        jobs_search(scope, query, pattern)
      when "tags"
        scope.where("tags.name LIKE ?", pattern)
      when "hostname"
        scope.where("spawned_processes.hostname LIKE ?", pattern)
      else
        scope
      end
    end

    def jobs_search(scope, query, pattern)
      if query.match?(/\A\d+\z/)
        scope.where("jobs.issue_title LIKE :pattern OR jobs.branch_name LIKE :pattern OR jobs.issue_number = :number",
          pattern:,
          number: query.to_i)
      else
        scope.where("jobs.issue_title LIKE :pattern OR jobs.branch_name LIKE :pattern", pattern:)
      end
    end

    def apply_order(field, scope)
      case field
      when "repository_id"
        scope.order(:owner, :name)
      when "epic_id"
        scope.order(:title)
      when "parent_job_id", "job_id"
        scope.order(created_at: :desc)
      when "tags"
        scope.order(Arel.sql("LOWER(tags.name)"))
      when "hostname"
        scope.order(Arel.sql("LOWER(spawned_processes.hostname)"))
      else
        scope
      end
    end

    def option_for(field, record)
      {
        "value" => field == "hostname" ? record.hostname : record.id,
        "label" => label_for(field, record)
      }
    end

    def label_for(field, record)
      case field
      when "repository_id"
        record.slug
      when "epic_id"
        Filters::Schema.epic_label(record)
      when "parent_job_id", "job_id"
        "##{record.issue_number || record.id} #{record.issue_title}".strip
      when "tags"
        record.name
      when "hostname"
        record.hostname
      end
    end
  end
end
