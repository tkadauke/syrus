module CiRepair
  class CheckRefresh
    Result = Data.define(:job, :head_sha, :state, :detail, :refreshed_at) do
      def failed_checks
        Array(detail[:failed_checks] || detail["failed_checks"])
      end

      def failed_check_summaries
        failed_checks.map do |check|
          {
            name: check[:name] || check["name"],
            conclusion: check[:conclusion] || check["conclusion"],
            details_url: check[:html_url] || check["html_url"] || check[:details_url] || check["details_url"] || check[:url] || check["url"],
            summary: check[:summary] || check["summary"]
          }.compact
        end
      end

      def payload
        {
          job_id: job.id,
          slug: job.slug,
          pr_number: job.pr_number || job.external_pr_number,
          head_sha: head_sha,
          pr_checks_state: state,
          pr_checks_checked_at: refreshed_at&.iso8601,
          failing_checks: failed_check_summaries
        }
      end
    end

    def self.call(job)
      new(job).call
    end

    def initialize(job)
      @job = job
    end

    def call
      pr = client.pull_request(pr_repository.slug, pr_number, bypass_cache: true)
      head_sha = pr.head&.sha
      raise ArgumentError, "PR head SHA is unavailable." if head_sha.blank?

      detail = client.check_runs_detail_for(pr_repository.slug, head_sha)
      refreshed_at = Time.current
      state = state_for(detail)
      @job.update_columns(
        pr_checks_sha: head_sha,
        pr_checks_state: state,
        pr_checks_checked_at: refreshed_at
      )

      Result.new(job: @job.reload, head_sha: head_sha, state: state, detail: detail, refreshed_at: refreshed_at)
    end

    private

    def pr_number
      @job.pr_number.presence || @job.external_pr_number.presence || raise(ArgumentError, "Job has no tracked PR.")
    end

    def pr_repository
      @pr_repository ||= @job.effective_pr_repository
    end

    def client
      @client ||= GithubClient.for(repository: pr_repository, user: @job.user)
    end

    def state_for(detail)
      if detail[:any_failed?] || detail["any_failed?"]
        "failing"
      elsif detail[:pending?] || detail["pending?"]
        "pending"
      elsif detail[:all_passed?] || detail["all_passed?"]
        "passing"
      else
        "unknown"
      end
    end
  end
end
