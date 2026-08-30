module TestInsights
  class RuntimeComparison
    include Rails.application.routes.url_helpers

    DEFAULT_LIMIT = 10
    MAX_LIMIT = 25

    class << self
      def call(...) = new(...).call
    end

    def initialize(user:, repository: nil, repository_id: nil, repository_slug: nil, test_identity_ids: nil, query: nil, grader_name: nil, limit: nil, baseline_run_id: nil, comparison_run_id: nil, baseline_job_id: nil, comparison_job_id: nil, baseline_window: nil, comparison_window: nil)
      @user = user
      @repository = repository
      @repository_id = repository_id
      @repository_slug = repository_slug
      @test_identity_ids = Array(test_identity_ids).compact
      @query = query.to_s.strip.presence
      @grader_name = grader_name.to_s.strip.presence
      @limit = clamp_limit(limit)
      @baseline_source = Source.build(
        repository: -> { resolve_repository },
        user: @user,
        run_id: baseline_run_id,
        job_id: baseline_job_id,
        window: baseline_window,
        label: "baseline"
      )
      @comparison_source = Source.build(
        repository: -> { resolve_repository },
        user: @user,
        run_id: comparison_run_id,
        job_id: comparison_job_id,
        window: comparison_window,
        label: "comparison"
      )
    end

    def call
      repository = resolve_repository
      identities = selected_identities(repository)
      baseline_stats = @baseline_source.stats_for(identities, grader_name: @grader_name)
      comparison_stats = @comparison_source.stats_for(identities, grader_name: @grader_name)

      {
        repository: repository_payload(repository),
        grader_name: @grader_name,
        limit: @limit,
        baseline: @baseline_source.payload,
        comparison: @comparison_source.payload,
        tests: identities.map { |identity| comparison_payload(identity, baseline_stats[identity.id], comparison_stats[identity.id]) }
      }
    end

    private

    def resolve_repository
      @resolved_repository ||= begin
        return accessible_scope.find(@repository.id) if @repository
        return accessible_scope.find(@repository_id) if @repository_id.present?

        owner, name = @repository_slug.to_s.strip.split("/", 2)
        raise ActiveRecord::RecordNotFound if owner.blank? || name.blank?

        accessible_scope.find_by!(owner: owner, name: name)
      end
    end

    def accessible_scope
      @user.admin? ? Repository.all : Repository.accessible_to(@user)
    end

    def selected_identities(repository)
      scope = repository.test_identities

      if @test_identity_ids.any?
        ids = @test_identity_ids.filter_map { |id| Integer(id, exception: false) }.uniq.first(MAX_LIMIT)
        identities_by_id = scope.where(id: ids).index_by(&:id)
        return ids.filter_map { |id| identities_by_id[id] }.first(@limit)
      end

      scope = scope.search_by_name(@query) if @query.present?
      candidate_ids_from_summary(scope, repository)
    end

    def candidate_ids_from_summary(scope, repository)
      grader_name = @grader_name || TestIdentityRuntimeSummary::ALL_GRADERS
      scope
        .joins(:test_identity_runtime_summaries)
        .where(test_identity_runtime_summaries: {
          repository_id: repository.id,
          grader_name: grader_name,
          window: TestIdentityRuntimeSummary::RECENT_100_WINDOW
        })
        .order(
          Arel.sql("test_identity_runtime_summaries.p95_duration_ms DESC"),
          Arel.sql("test_identity_runtime_summaries.avg_duration_ms DESC"),
          Arel.sql("test_identities.id DESC")
        )
        .limit(@limit)
        .to_a
    end

    def comparison_payload(identity, baseline, comparison)
      {
        test: {
          id: identity.id,
          type: "TestIdentity",
          suite_name: identity.suite_name,
          name: identity.name,
          file_path: identity.file_path,
          fingerprint: identity.fingerprint,
          links: {
            app_path: repository_path(identity.repository, tab: "tests", test_id: identity.id)
          }
        },
        baseline: baseline || Source::EMPTY_STATS,
        comparison: comparison || Source::EMPTY_STATS,
        delta: delta_payload(baseline, comparison)
      }
    end

    def delta_payload(baseline, comparison)
      baseline ||= Source::EMPTY_STATS
      comparison ||= Source::EMPTY_STATS

      {
        avg_duration_ms: duration_delta(baseline[:avg_duration_ms], comparison[:avg_duration_ms]),
        p50_duration_ms: duration_delta(baseline[:p50_duration_ms], comparison[:p50_duration_ms]),
        p95_duration_ms: duration_delta(baseline[:p95_duration_ms], comparison[:p95_duration_ms]),
        latest_duration_ms: duration_delta(baseline[:latest_duration_ms], comparison[:latest_duration_ms]),
        sample_count: comparison.fetch(:sample_count) - baseline.fetch(:sample_count)
      }
    end

    def duration_delta(before, after)
      return nil if before.nil? || after.nil?

      change = after - before
      {
        ms: change,
        percent: before.positive? ? ((change.to_f / before) * 100).round(1) : nil
      }
    end

    def repository_payload(repository)
      {
        id: repository.id,
        slug: repository.slug,
        github_url: "https://github.com/#{repository.slug}"
      }
    end

    def clamp_limit(value)
      parsed = Integer(value, exception: false)
      parsed = DEFAULT_LIMIT unless parsed&.positive?
      parsed.clamp(1, MAX_LIMIT)
    end

    class Source
      EMPTY_STATS = {
        sample_count: 0,
        avg_duration_ms: nil,
        p50_duration_ms: nil,
        p95_duration_ms: nil,
        latest_duration_ms: nil,
        min_duration_ms: nil,
        max_duration_ms: nil,
        first_observed_at: nil,
        last_observed_at: nil
      }.freeze

      def self.build(repository:, user:, run_id:, job_id:, window:, label:)
        candidates = [
          RunSource.build(repository: repository, user: user, run_id: run_id, label: label),
          JobSource.build(repository: repository, user: user, job_id: job_id, label: label),
          WindowSource.build(repository: repository, window: window, label: label)
        ].compact

        raise ArgumentError, "#{label} must specify exactly one of run_id, job_id, or window" unless candidates.one?

        candidates.sole
      end

      def initialize(repository:, label:)
        @repository = repository
        @label = label
      end

      def stats_for(identities, grader_name:)
        ids = identities.map(&:id)
        return {} if ids.empty?

        rows = duration_rows(ids, grader_name: grader_name)
        grouped = rows.group_by { |row| row.fetch(:test_identity_id) }
        ids.index_with { |id| stats_for_rows(grouped.fetch(id, [])) }
      end

      def payload
        {
          type: type,
          label: @label
        }.merge(payload_details).merge(worker_health: worker_health_payload).compact
      end

      private

      def stats_for_rows(rows)
        return EMPTY_STATS if rows.empty?

        durations = rows.filter_map { |row| row.fetch(:duration_ms) }.sort
        return EMPTY_STATS if durations.empty?

        ordered = rows.sort_by { |row| [ row.fetch(:created_at), row.fetch(:test_case_id) ] }

        {
          sample_count: durations.size,
          avg_duration_ms: (durations.sum.to_f / durations.size).round,
          p50_duration_ms: percentile(durations, 0.50),
          p95_duration_ms: percentile(durations, 0.95),
          latest_duration_ms: ordered.last.fetch(:duration_ms),
          min_duration_ms: durations.first,
          max_duration_ms: durations.last,
          first_observed_at: iso8601(ordered.first.fetch(:created_at)),
          last_observed_at: iso8601(ordered.last.fetch(:created_at))
        }
      end

      def base_case_scope(identity_ids, grader_name:)
        scope = TestCase.joins(:test_run).where(test_identity_id: identity_ids)
        scope = scope.where(test_runs: { grader_name: grader_name }) if grader_name.present?
        scope.where.not(duration_ms: nil)
      end

      def rows_from(scope)
        scope
          .select(:id, :test_identity_id, :duration_ms, :created_at)
          .map do |test_case|
            {
              test_case_id: test_case.id,
              test_identity_id: test_case.test_identity_id,
              duration_ms: test_case.duration_ms,
              created_at: test_case.created_at
            }
          end
      end

      def percentile(sorted_values, percentile)
        sorted_values[[ (sorted_values.size * percentile).ceil - 1, 0 ].max]
      end

      def worker_health_payload = nil
      def iso8601(value) = value.respond_to?(:iso8601) ? value.iso8601 : value&.to_s
    end

    class RunSource < Source
      def self.build(repository:, user:, run_id:, label:)
        return nil if run_id.blank?

        repository_record = repository.call
        run = run_scope(user).where(jobs: { repository_id: repository_record.id }).find(normalize_numeric_ref(run_id, prefix: "run"))
        new(repository: repository_record, label: label, run: run)
      end

      def initialize(repository:, label:, run:)
        super(repository: repository, label: label)
        @run = run
      end

      private

      def self.run_scope(user)
        user.admin? ? Run.joins(:job) : Run.joins(job: :repository).merge(Job.accessible_to(user))
      end

      def self.normalize_numeric_ref(value, prefix:)
        ref = value.to_s.strip
        ref = ref[(prefix.length + 1)..] if ref.match?(/\A#{Regexp.escape(prefix)}-/i)
        Integer(ref)
      rescue ArgumentError, TypeError
        raise ActiveRecord::RecordNotFound
      end

      def type = "run"

      def payload_details
        {
          run_id: @run.id,
          run_slug: "RUN-#{@run.id}",
          job_id: @run.job_id,
          job_slug: @run.job.slug,
          workflow_id: @run.workflow_id
        }
      end

      def duration_rows(identity_ids, grader_name:)
        rows_from(base_case_scope(identity_ids, grader_name: grader_name).where(test_runs: { run_id: @run.id }))
      end

      def worker_health_payload
        WorkerHealthRunCorrelation.for_run(@run, sample_limit: 0).slice(:run_id, :primary_hostname, :range, :pressure, :command_spans)
      end
    end

    class JobSource < Source
      def self.build(repository:, user:, job_id:, label:)
        return nil if job_id.blank?

        repository_record = repository.call
        job = job_scope(user).where(repository_id: repository_record.id).find(normalize_numeric_ref(job_id, prefix: "job"))
        new(repository: repository_record, label: label, job: job)
      end

      def initialize(repository:, label:, job:)
        super(repository: repository, label: label)
        @job = job
      end

      private

      def self.job_scope(user)
        user.admin? ? Job.all : Job.accessible_to(user)
      end

      def self.normalize_numeric_ref(value, prefix:)
        ref = value.to_s.strip
        ref = ref[(prefix.length + 1)..] if ref.match?(/\A#{Regexp.escape(prefix)}-/i)
        Integer(ref)
      rescue ArgumentError, TypeError
        raise ActiveRecord::RecordNotFound
      end

      def type = "job"

      def payload_details
        {
          job_id: @job.id,
          job_slug: @job.slug,
          workflow_id: latest_workflow&.id
        }
      end

      def duration_rows(identity_ids, grader_name:)
        workflow = latest_workflow
        return [] unless workflow

        test_run_ids = TestRun.joins(run: { step: :workflow })
          .where(workflows: { id: workflow.id })
          .then { |scope| grader_name.present? ? scope.where(grader_name: grader_name) : scope }
          .pluck(:id)
        return [] if test_run_ids.empty?

        rows_from(TestCase.where(test_identity_id: identity_ids, test_run_id: test_run_ids).where.not(duration_ms: nil))
      end

      def latest_workflow
        @latest_workflow ||= @job.workflows
          .joins(steps: { runs: :test_runs })
          .reorder(created_at: :desc, id: :desc)
          .first
      end
    end

    class WindowSource < Source
      def self.build(repository:, window:, label:)
        normalized = (window || {}).to_h.with_indifferent_access
        return nil if normalized.blank?

        starts_at = time_value(normalized[:starts_at] || normalized[:start] || normalized[:from])
        ends_at = time_value(normalized[:ends_at] || normalized[:end] || normalized[:to])
        raise ArgumentError, "#{label} window requires starts_at and ends_at" if starts_at.blank? || ends_at.blank?
        raise ArgumentError, "#{label} window starts_at must be before ends_at" unless starts_at < ends_at

        new(repository: repository.call, label: label, starts_at: starts_at, ends_at: ends_at)
      end

      def initialize(repository:, label:, starts_at:, ends_at:)
        super(repository: repository, label: label)
        @starts_at = starts_at
        @ends_at = ends_at
      end

      private

      def self.time_value(value)
        return nil if value.blank?
        return value.to_time if value.respond_to?(:to_time)

        Time.zone.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      def type = "window"

      def payload_details
        {
          starts_at: @starts_at.iso8601,
          ends_at: @ends_at.iso8601
        }
      end

      def duration_rows(identity_ids, grader_name:)
        rows_from(
          base_case_scope(identity_ids, grader_name: grader_name)
            .where(repository_id: @repository.id, created_at: @starts_at..@ends_at)
        )
      end
    end
  end
end
