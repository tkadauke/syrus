module Jobs
  class DiffReviewVersionBackfill
    Result = Struct.new(:checked, :created, :reused, :skipped, :errors, :skips, keyword_init: true)

    def initialize(scope: default_scope, logger: Rails.logger)
      @scope = scope
      @logger = logger
    end

    def call(dry_run: false)
      result = Result.new(checked: 0, created: 0, reused: 0, skipped: 0, errors: 0, skips: [])

      scope.includes(:repository, :user).find_each do |job|
        result.checked += 1
        outcome = dry_run ? dry_run_outcome(job) : DiffReviewVersions::FinalSnapshot.materialize(job: job, user: job.user, logger: logger)
        record_outcome(result, job, outcome, dry_run: dry_run)
      rescue => e
        result.errors += 1
        logger.warn("[DiffReviewVersionBackfill] failed #{job.slug}: #{e.class}: #{e.message}")
      end

      result
    end

    private

    attr_reader :scope, :logger

    def self.default_scope
      Job.closed_threads.where.not(branch_name: [ nil, "" ])
    end

    def default_scope
      self.class.default_scope
    end

    def dry_run_outcome(job)
      existing = job.diff_review_versions
                    .where(reason: "source_diff", source_key: DiffReviewVersions::FinalSnapshot::FINAL_SOURCE_KEY)
                    .latest_first
                    .detect(&:reviewable_all_changes?)
      return DiffReviewVersions::FinalSnapshot::Result.new(version: existing, status: :reused, reason: "existing_final_snapshot") if existing

      DiffReviewVersions::FinalSnapshot::Result.new(version: nil, status: :skipped, reason: "dry_run")
    end

    def record_outcome(result, job, outcome, dry_run:)
      case outcome.status
      when :created
        result.created += 1
        logger.info("[DiffReviewVersionBackfill] #{dry_run ? "would create" : "created"} final review snapshot for #{job.slug}")
      when :reused
        result.reused += 1
        logger.info("[DiffReviewVersionBackfill] reused final review snapshot for #{job.slug}")
      else
        result.skipped += 1
        result.skips << { "job_id" => job.id, "job_slug" => job.slug, "reason" => outcome.reason }
        logger.info("[DiffReviewVersionBackfill] skipped #{job.slug}: #{outcome.reason}")
      end
    end
  end
end
