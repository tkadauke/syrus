module GithubSource
  class ApiUsagePayload
    DEFAULT_HOURS = 24
    MAX_HOURS = 168
    LIMIT = 100

    def initialize(params:)
      @params = params
    end

    def as_json(*)
      {
        hours: hours,
        filter: filter_tree,
        filter_schema: filter_schema,
        generated_at: Time.current.iso8601,
        totals: totals,
        by_operation: by_operation,
        by_repository: by_repository,
        recent_rate_limits: recent_rate_limits
      }
    end

    private

    attr_reader :params

    def scope
      @scope ||= begin
        relation = GithubApiUsageRollup.where("bucket_started_at >= ?", hours.hours.ago)
        relation = relation.where(operation: operation) if operation.present?
        relation = relation.where(resource: resource) if resource.present?
        relation = relation.where(auth_source: auth_source) if auth_source.present?
        relation = relation.where(credential_key: credential_key) if credential_key.present?
        relation = relation.where(repository_id: repository_id) if repository_id.present?
        relation = relation.where("repo_slug LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(repo_slug)}%") if repo_slug.present?
        relation = relation.where(user_id: user_id) if user_id.present?
        relation = relation.where(installation_id: installation_id) if installation_id.present?
        relation = relation.where(last_status: status) if status.present?
        relation = relation.where("rate_limited_count > 0") if rate_limited?
        relation = relation.where(bucket_started_at: bucket_since..) if bucket_since
        relation = relation.where(last_seen_at: last_seen_since..) if last_seen_since
        relation
      end
    end

    def hours
      @hours ||= params.fetch(:hours, DEFAULT_HOURS).to_i.clamp(1, MAX_HOURS)
    end

    def filter_tree
      chips = [ { field: "hours", op: "is", value: hours.to_s } ]
      flat_filter_fields.each do |field|
        value = send(field)
        chips << { field: field.to_s, op: "is", value: value.to_s } if value.present?
      end
      chips << { field: "rate_limited", op: "is", value: "true" } if rate_limited?
      chips << { field: "bucket_since", op: "is", value: params[:bucket_since].to_s } if params[:bucket_since].present?
      chips << { field: "last_seen_since", op: "is", value: params[:last_seen_since].to_s } if params[:last_seen_since].present?
      { and: chips }
    end

    def filter_schema
      [
        {
          field: "hours",
          label: "Window",
          bucket: "enum",
          operators: [ "is" ],
          values: [
            { label: "1 hour", value: "1" },
            { label: "6 hours", value: "6" },
            { label: "24 hours", value: "24" },
            { label: "3 days", value: "72" },
            { label: "7 days", value: "168" }
          ]
        },
        { field: "operation", label: "Operation", bucket: "text", operators: [ "is" ], expansions: { placeholder: "pull_request" } },
        { field: "resource", label: "Resource", bucket: "text", operators: [ "is" ], expansions: { placeholder: "core" } },
        { field: "auth_source", label: "Auth source", bucket: "text", operators: [ "is" ], expansions: { placeholder: "pat" } },
        { field: "credential_key", label: "Credential key", bucket: "text", operators: [ "is" ], expansions: { placeholder: "user:1" } },
        { field: "repository_id", label: "Repository ID", bucket: "number", operators: [ "is" ] },
        { field: "repo_slug", label: "Repository slug", bucket: "text", operators: [ "is" ], expansions: { placeholder: "owner/name" } },
        { field: "user_id", label: "User ID", bucket: "number", operators: [ "is" ] },
        { field: "installation_id", label: "Installation ID", bucket: "number", operators: [ "is" ] },
        { field: "status", label: "Last status", bucket: "number", operators: [ "is" ] },
        { field: "rate_limited", label: "Rate limited", bucket: "enum", operators: [ "is" ], values: [ { label: "Yes", value: "true" } ] },
        { field: "bucket_since", label: "Bucket since", bucket: "text", operators: [ "is" ], expansions: { placeholder: "2026-09-25T00:00:00Z" } },
        { field: "last_seen_since", label: "Last seen since", bucket: "text", operators: [ "is" ], expansions: { placeholder: "1h" } }
      ]
    end

    def totals
      row = scope.select(
        "COALESCE(SUM(request_count), 0) AS requests",
        "COALESCE(SUM(rate_limited_count), 0) AS rate_limited"
      ).take
      {
        requests: row.requests.to_i,
        rate_limited: row.rate_limited.to_i
      }
    end

    def by_operation
      scope
        .group(:auth_source, :operation, :resource)
        .select(
          :auth_source,
          :operation,
          :resource,
          "SUM(request_count) AS requests",
          "SUM(rate_limited_count) AS rate_limited",
          "MIN(last_remaining) AS min_remaining",
          "MAX(last_limit) AS last_limit",
          "MAX(last_status) AS last_status",
          "MAX(last_reset_at) AS last_reset_at",
          "MAX(credential_key) AS credential_key",
          "MAX(last_seen_at) AS last_seen_at"
        )
        .order(Arel.sql("requests DESC"))
        .limit(LIMIT)
        .map { |row| rollup_row(row) }
    end

    def by_repository
      scope
        .where.not(repo_slug: nil)
        .group(:auth_source, :repo_slug)
        .select(
          :auth_source,
          :repo_slug,
          "SUM(request_count) AS requests",
          "SUM(rate_limited_count) AS rate_limited",
          "MIN(last_remaining) AS min_remaining",
          "MAX(last_limit) AS last_limit",
          "MAX(last_status) AS last_status",
          "MAX(last_reset_at) AS last_reset_at",
          "MAX(credential_key) AS credential_key",
          "MAX(last_seen_at) AS last_seen_at"
        )
        .order(Arel.sql("requests DESC"))
        .limit(LIMIT)
        .map do |row|
          {
            auth_source: row.auth_source,
            repo_slug: row.repo_slug,
            requests: row.requests.to_i,
            rate_limited: row.rate_limited.to_i,
            min_remaining: row.min_remaining&.to_i,
            last_limit: row.last_limit&.to_i,
            last_status: row.last_status&.to_i,
            last_reset_at: row.last_reset_at&.iso8601,
            credential_key: row.credential_key,
            last_seen_at: row.last_seen_at&.iso8601
          }
        end
    end

    def recent_rate_limits
      scope
        .where("rate_limited_count > 0")
        .order(last_seen_at: :desc)
        .limit(25)
        .map do |row|
          {
            auth_source: row.auth_source,
            operation: row.operation,
            resource: row.resource,
            requests: row.request_count.to_i,
            rate_limited: row.rate_limited_count.to_i,
            min_remaining: row.last_remaining&.to_i,
            last_limit: row.last_limit&.to_i,
            last_status: row.last_status&.to_i,
            last_reset_at: row.last_reset_at&.iso8601,
            credential_key: row.credential_key,
            bucket_started_at: row.bucket_started_at&.iso8601,
            last_seen_at: row.last_seen_at&.iso8601,
            repo_slug: row.repo_slug
          }
        end
    end

    def rollup_row(row)
      {
        auth_source: row.auth_source,
        operation: row.operation,
        resource: row.resource,
        requests: row.requests.to_i,
        rate_limited: row.rate_limited.to_i,
        min_remaining: row.min_remaining&.to_i,
        last_limit: row.respond_to?(:last_limit) ? row.last_limit&.to_i : nil,
        last_status: row.respond_to?(:last_status) ? row.last_status&.to_i : nil,
        last_reset_at: row.respond_to?(:last_reset_at) ? row.last_reset_at&.iso8601 : nil,
        credential_key: row.respond_to?(:credential_key) ? row.credential_key : nil,
        last_seen_at: row.last_seen_at&.iso8601
      }
    end

    def flat_filter_fields
      %i[operation resource auth_source credential_key repository_id repo_slug user_id installation_id status]
    end

    def operation = params[:operation].to_s.strip.presence
    def resource = params[:resource].to_s.strip.presence
    def auth_source = params[:auth_source].to_s.strip.presence
    def credential_key = params[:credential_key].to_s.strip.presence
    def repo_slug = params[:repo_slug].presence || params[:repository].presence
    def repository_id = integer_param(:repository_id)
    def user_id = integer_param(:user_id)
    def installation_id = integer_param(:installation_id)
    def status = integer_param(:status)

    def rate_limited?
      ActiveModel::Type::Boolean.new.cast(params[:rate_limited])
    end

    def bucket_since
      parse_time(params[:bucket_since])
    end

    def last_seen_since
      parse_time(params[:last_seen_since])
    end

    def integer_param(key)
      Integer(params[key], exception: false)
    end

    def parse_time(value)
      return if value.blank?
      text = value.to_s.strip
      return Integer(text, exception: false)&.hours&.ago if text.match?(/\A\d+\z/)
      if (match = text.match(/\A(\d+)(m|h|d)\z/i))
        amount = match[1].to_i
        return amount.minutes.ago if match[2].downcase == "m"
        return amount.hours.ago if match[2].downcase == "h"
        return amount.days.ago
      end
      Time.zone.parse(text)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
