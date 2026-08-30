module TestInsights
  class Query
    include Rails.application.routes.url_helpers

    DEFAULT_LIMIT = 25
    MAX_LIMIT = 100
    MAX_FAILURE_RATE_CANDIDATES = 500
    FAILURE_RATE_CANDIDATE_MULTIPLIER = 5
    DEFAULT_SLOW_THRESHOLD_MS = 1_000
    DEFAULT_LOOKBACK = TestIdentity::LIST_LOOKBACK

    Result = Struct.new(:repository, :category, :sort, :direction, :query, :limit, :tests, keyword_init: true)

    class << self
      def call(...) = new(...).call
    end

    def initialize(user:, repository: nil, repository_id: nil, repository_slug: nil, category: nil, sort: nil, direction: nil, query: nil, limit: nil, filters: {}, grader_name: nil)
      @user = user
      @repository = repository
      @repository_id = repository_id
      @repository_slug = repository_slug
      @category = Category.for(category)
      @sort = Sort.for(sort)
      @direction = Direction.for(direction)
      @query = query.to_s.strip.presence
      @limit = clamp_limit(limit)
      @filters = Filters.new(filters)
      @grader_name = grader_name.to_s.strip.presence
    end

    def call
      repository = resolve_repository
      scope = @category.apply(repository.test_identities)
      scope = scope.search_by_name(@query) if @query.present?
      scope = @filters.apply_summary_filters(scope)
      scope = apply_grader_filter(scope, repository)

      identities =
        if @sort.requires_in_memory_failure_rate?
          candidates = failure_rate_candidates(scope)
          @stats_by_identity_id = recent_stats_by_identity_id(candidates)
          failure_rate_sorted_identities(candidates)
        else
          @sort.apply(scope, @direction).limit(identity_candidate_limit).to_a
        end

      @stats_by_identity_id = recent_stats_by_identity_id(identities)
      latest_cases = latest_cases_by_identity_id(identities)
      tests = identities.map { |identity| test_identity_json(identity, latest_cases[identity.id], @stats_by_identity_id.fetch(identity.id)) }

      tests = @filters.apply_failure_rate_filters(tests).first(@limit)

      Result.new(
        repository: repository,
        category: @category.name,
        sort: @sort.name,
        direction: @direction.name,
        query: @query,
        limit: @limit,
        tests: tests
      )
    end

    private

    def apply_grader_filter(scope, repository)
      return scope unless @grader_name

      matching_identity_ids = TestCase
        .joins(:test_run)
        .where(repository_id: repository.id, test_runs: { grader_name: @grader_name })
        .where.not(test_identity_id: nil)
        .select(:test_identity_id)

      scope.where(id: matching_identity_ids)
    end

    def resolve_repository
      return accessible_scope.find(@repository.id) if @repository
      return accessible_scope.find(@repository_id) if @repository_id.present?

      slug = @repository_slug.to_s.strip
      owner, name = slug.split("/", 2)
      raise ActiveRecord::RecordNotFound, "Couldn't find Repository" if owner.blank? || name.blank?

      accessible_scope.find_by!(owner: owner, name: name)
    end

    def accessible_scope
      @user.admin? ? Repository.all : Repository.accessible_to(@user)
    end

    def clamp_limit(limit)
      value = Integer(limit, exception: false)
      value = DEFAULT_LIMIT unless value&.positive?
      value.clamp(1, MAX_LIMIT)
    end

    def failure_rate_candidates(scope)
      scope.order(last_failed_at: @direction.desc? ? :desc : :asc, last_seen_at: :desc, id: :desc).limit(identity_candidate_limit).to_a
    end

    def failure_rate_sorted_identities(candidates)
      candidates
        .sort_by { |identity| failure_rate_sort_key(identity, @stats_by_identity_id.fetch(identity.id)) }
    end

    def identity_candidate_limit
      return @limit unless @sort.requires_in_memory_failure_rate? || @filters.failure_rate_filter?

      [ @limit * FAILURE_RATE_CANDIDATE_MULTIPLIER, MAX_FAILURE_RATE_CANDIDATES ].min
    end

    def failure_rate_sort_key(identity, stats)
      rate = stats.fetch(:failure_rate)
      @direction.desc? ? [ -rate, -stats.fetch(:failed_count), identity.name ] : [ rate, stats.fetch(:failed_count), identity.name ]
    end

    def recent_stats_by_identity_id(identities)
      existing = @stats_by_identity_id || {}
      missing = identities.reject { |identity| existing.key?(identity.id) }
      return existing if missing.empty?

      existing.merge(RecentStats.load(missing, lookback: @filters.lookback))
    end

    def latest_cases_by_identity_id(identities)
      ids = identities.map(&:id)
      return {} if ids.empty?

      latest_cases = TestIdentity.latest_cases_for(ids).to_a
      return {} if latest_cases.empty?

      TestCase.includes(test_run: { run: :job })
        .where(id: latest_cases.map(&:id))
        .index_by(&:test_identity_id)
    end

    def test_identity_json(identity, latest_case, stats)
      {
        id: identity.id,
        type: "TestIdentity",
        suite_name: identity.suite_name,
        name: identity.name,
        file_path: identity.file_path,
        fingerprint: identity.fingerprint,
        last_status: identity.last_status,
        last_seen_at: iso8601(identity.last_seen_at),
        last_failed_at: iso8601(identity.last_failed_at),
        last_passed_at: iso8601(identity.last_passed_at),
        last_duration_ms: identity.last_duration_ms,
        total_count: stats.fetch(:total_count),
        failed_count: stats.fetch(:failed_count),
        passed_count: stats.fetch(:passed_count),
        failure_rate: stats.fetch(:failure_rate).round(4),
        avg_duration_ms: stats.fetch(:avg_duration_ms),
        interesting_reasons: identity.interesting_reasons(stats: stats),
        links: {
          app_path: repository_path(identity.repository, tab: "tests", test_id: identity.id)
        },
        latest: latest_case_json(latest_case)
      }
    end

    def latest_case_json(test_case)
      return nil unless test_case

      test_run = test_case.test_run
      run = test_run.run
      job = run.job

      {
        test_case: {
          id: test_case.id,
          type: "TestCase",
          status: test_case.status,
          duration_ms: test_case.duration_ms,
          created_at: iso8601(test_case.created_at)
        },
        test_run: {
          id: test_run.id,
          type: "TestRun",
          grader_name: test_run.grader_name
        },
        run: {
          id: run.id,
          type: "Run",
          slug: "RUN-#{run.id}",
          path: "#{job_path(job, tab: "workflows")}#run-#{run.id}"
        },
        job: {
          id: job.id,
          type: "Job",
          slug: job.slug,
          title: job.issue_title,
          path: job_path(job)
        }
      }
    end

    def iso8601(value)
      value.respond_to?(:iso8601) ? value.iso8601 : value&.to_s
    end

    class Category
      REGISTRY = {}

      attr_reader :name

      def self.register(value, klass)
        REGISTRY[value] = klass
      end

      def self.for(value)
        REGISTRY.fetch(value.to_s.presence || "recently_seen", RecentlySeen).new
      end

      def initialize(name)
        @name = name
      end
    end

    class RecentlySeen < Category
      def initialize = super("recently_seen")

      def apply(scope)
        scope.where.not(last_seen_at: nil)
      end
    end

    class Failing < Category
      def initialize = super("failing")

      def apply(scope)
        scope.where(last_status: %w[failed error])
      end
    end

    class Flaky < Category
      def initialize = super("flaky")

      def apply(scope)
        scope.where.not(last_failed_at: nil).where.not(last_passed_at: nil)
      end
    end

    class Slow < Category
      def initialize = super("slow")

      def apply(scope)
        scope.where.not(last_duration_ms: nil).where("last_duration_ms >= ?", DEFAULT_SLOW_THRESHOLD_MS)
      end
    end

    Category.register("recently_seen", RecentlySeen)
    Category.register("recent", RecentlySeen)
    Category.register("failing", Failing)
    Category.register("failed", Failing)
    Category.register("flaky", Flaky)
    Category.register("slow", Slow)

    class Direction
      REGISTRY = {}

      attr_reader :name

      def self.register(value, direction)
        REGISTRY[value] = direction
      end

      def self.for(value)
        REGISTRY.fetch(value.to_s.downcase.presence || "desc", REGISTRY.fetch("desc"))
      end

      def initialize(name)
        @name = name
      end

      def order_value = name.to_sym
      def desc? = name == "desc"
    end

    Direction.register("asc", Direction.new("asc"))
    Direction.register("desc", Direction.new("desc"))

    class Sort
      REGISTRY = {}

      attr_reader :name

      def self.register(value, sort)
        REGISTRY[value] = sort
      end

      def self.for(value)
        REGISTRY.fetch(value.to_s.presence || "last_seen", REGISTRY.fetch("last_seen"))
      end

      def initialize(name)
        @name = name
      end

      def requires_in_memory_failure_rate? = false
    end

    class ColumnSort < Sort
      def initialize(name, columns)
        super(name)
        @columns = columns
      end

      def apply(scope, direction)
        order = @columns.index_with(direction.order_value)
        scope.order(order.merge(id: direction.order_value))
      end
    end

    class FailureRateSort < Sort
      def initialize = super("failure_rate")

      def requires_in_memory_failure_rate? = true
    end

    Sort.register("last_seen", ColumnSort.new("last_seen", [ :last_seen_at ]))
    Sort.register("last_failed", ColumnSort.new("last_failed", [ :last_failed_at ]))
    Sort.register("last_duration", ColumnSort.new("last_duration", [ :last_duration_ms, :last_seen_at ]))
    Sort.register("failure_rate", FailureRateSort.new)

    class Filters
      attr_reader :lookback

      def initialize(filters)
        @filters = (filters || {}).to_h.with_indifferent_access
        @lookback = (integer_filter(:lookback, default: DEFAULT_LOOKBACK) || DEFAULT_LOOKBACK).clamp(1, 100)
      end

      def apply_summary_filters(scope)
        scope = apply_numeric_filter(scope, :last_duration_ms, :min_last_duration_ms, ">=")
        scope = apply_numeric_filter(scope, :last_duration_ms, :max_last_duration_ms, "<=")
        scope = apply_time_filter(scope, :last_failed_at, :last_failed_since, ">=")
        scope = apply_time_filter(scope, :last_failed_at, :last_failed_before, "<=")
        scope = apply_time_filter(scope, :last_seen_at, :last_seen_since, ">=")
        apply_time_filter(scope, :last_seen_at, :last_seen_before, "<=")
      end

      def apply_failure_rate_filters(tests)
        min = float_filter(:min_failure_rate)
        max = float_filter(:max_failure_rate)
        return tests if min.nil? && max.nil?

        tests.select do |test|
          rate = test.fetch(:failure_rate)
          (min.nil? || rate >= min) && (max.nil? || rate <= max)
        end
      end

      def failure_rate_filter?
        float_filter(:min_failure_rate).present? || float_filter(:max_failure_rate).present?
      end

      private

      def apply_numeric_filter(scope, column, key, operator)
        value = integer_filter(key)
        return scope unless value

        scope.where("#{column} #{operator} ?", value)
      end

      def apply_time_filter(scope, column, key, operator)
        value = time_filter(key)
        return scope unless value

        scope.where("#{column} #{operator} ?", value)
      end

      def integer_filter(key, default: nil)
        value = @filters.fetch(key, default)
        Integer(value, exception: false)
      end

      def float_filter(key)
        value = @filters[key]
        return nil if value.blank?

        Float(value, exception: false)&.clamp(0.0, 1.0)
      end

      def time_filter(key)
        value = @filters[key]
        return nil if value.blank?
        return value if value.respond_to?(:to_time)

        Time.zone.parse(value.to_s)
      rescue ArgumentError
        nil
      end
    end

    class RecentStats
      EMPTY_STATS = {
        total_count: 0,
        failed_count: 0,
        passed_count: 0,
        failure_rate: 0.0,
        avg_duration_ms: nil
      }.freeze

      def self.load(identities, lookback:)
        ids = identities.map(&:id)
        stats_by_id = ids.index_with { EMPTY_STATS.dup }
        return stats_by_id if ids.empty?

        ranked_cases = TestCase
          .where(test_identity_id: ids)
          .select(
            "test_cases.test_identity_id",
            "test_cases.status",
            "test_cases.duration_ms",
            "ROW_NUMBER() OVER (PARTITION BY test_cases.test_identity_id ORDER BY test_cases.created_at DESC, test_cases.id DESC) AS syrus_recent_rank"
          )

        rows = TestCase
          .from("(#{ranked_cases.to_sql}) test_cases")
          .where("syrus_recent_rank <= ?", lookback)
          .pluck(:test_identity_id, :status, :duration_ms)

        rows.group_by(&:first).each do |identity_id, grouped_rows|
          stats_by_id[identity_id] = stats_for(grouped_rows)
        end

        stats_by_id
      end

      def self.stats_for(rows)
        total = rows.size
        failed = rows.count { |_identity_id, status, _duration| status == "failed" || status == "error" }
        passed = rows.count { |_identity_id, status, _duration| status == "passed" }
        durations = rows.filter_map { |_identity_id, _status, duration| duration }

        {
          total_count: total,
          failed_count: failed,
          passed_count: passed,
          failure_rate: total.positive? ? (failed.to_f / total) : 0.0,
          avg_duration_ms: durations.any? ? (durations.sum.to_f / durations.size).round : nil
        }
      end
    end
  end
end
