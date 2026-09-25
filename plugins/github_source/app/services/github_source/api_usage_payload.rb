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
      @scope ||= GithubApiUsageRollup.where("bucket_started_at >= ?", hours.hours.ago)
    end

    def hours
      @hours ||= params.fetch(:hours, DEFAULT_HOURS).to_i.clamp(1, MAX_HOURS)
    end

    def filter_tree
      { and: [ { field: "hours", op: "is", value: hours.to_s } ] }
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
        }
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
        last_seen_at: row.last_seen_at&.iso8601
      }
    end
  end
end
