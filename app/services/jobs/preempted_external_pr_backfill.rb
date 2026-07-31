module Jobs
  class PreemptedExternalPrBackfill
    Result = Struct.new(:checked, :reopened, :skipped, :errors, keyword_init: true)

    def initialize(scope: default_scope, client_factory: nil, logger: Rails.logger)
      @scope = scope
      @client_factory = client_factory || ->(job) { GithubClient.for(repository: job.repository, user: job.user) }
      @logger = logger
    end

    def call(dry_run: false)
      result = Result.new(checked: 0, reopened: 0, skipped: 0, errors: 0)

      scope.includes(:repository, :user).find_each do |job|
        result.checked += 1
        pr = client_for(job).pull_request(job.repository.slug, job.external_pr_number, bypass_cache: true)

        if open_unmerged_pr?(pr)
          result.reopened += 1
          job.mark_externally_implemented!(job.external_pr_number) unless dry_run
          logger.info("[PreemptedExternalPrBackfill] #{dry_run ? "would reopen" : "reopened"} #{job.slug} for external PR ##{job.external_pr_number}")
        else
          result.skipped += 1
          logger.info("[PreemptedExternalPrBackfill] skipped #{job.slug}: external PR ##{job.external_pr_number} is #{pr_state(pr)}")
        end
      rescue Octokit::NotFound => e
        result.skipped += 1
        logger.warn("[PreemptedExternalPrBackfill] skipped #{job.slug}: external PR ##{job.external_pr_number} not found (#{e.message})")
      rescue Octokit::Error, ArgumentError => e
        result.errors += 1
        logger.warn("[PreemptedExternalPrBackfill] failed #{job.slug}: #{e.class}: #{e.message}")
      end

      result
    end

    private

    attr_reader :scope, :client_factory, :logger

    def self.default_scope
      Job.issue_kind
         .closed_threads
         .where(closure_reason: "preempted")
         .where.not(external_pr_number: nil)
    end

    def default_scope
      self.class.default_scope
    end

    def client_for(job)
      client_factory.call(job)
    end

    def open_unmerged_pr?(pr)
      pr.state == "open" && !pr.merged
    end

    def pr_state(pr)
      return "merged" if pr.merged

      pr.state.presence || "unknown"
    end
  end
end
