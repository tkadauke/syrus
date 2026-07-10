module Steps
  # Non-agentic step that posts or updates the coverage report comment on an
  # existing PR. Inserted after coverage_analyze in subsequent-workflow chains
  # (pr_comment, chat_feedback) where the PR already exists. For initial
  # workflows the same posting logic lives in Steps::PrOpen, which already
  # has the PR number in hand.
  #
  # No-ops gracefully when:
  #   - coverage was not configured or artifacts are unavailable
  #   - pr_comment: false in the coverage plan
  #   - the Job has no PR yet (shouldn't happen here, but safe to guard)
  class CoveragePrComment < Base
    def call
      pr_comment_body = workflow.artifact("coverage")&.[]("pr_comment_body")

      unless pr_comment_body.present?
        log("[coverage_pr_comment] no PR comment body in coverage artifact — skipping")
        return
      end

      pr_number = job.pr_number
      unless pr_number.present?
        log("[coverage_pr_comment] no PR number for job — skipping")
        return
      end

      pr_repo   = job.effective_pr_repository
      client    = GithubClient.for(repository: pr_repo, user: job.user)
      repo_slug = pr_repo.slug

      upsert_coverage_comment(client, repo_slug, pr_number, pr_comment_body)
    end

    private

    def upsert_coverage_comment(client, repo_slug, pr_number, body)
      existing = find_existing_coverage_comment(client, repo_slug, pr_number)

      if existing
        client.update_issue_comment(repo_slug, existing.id, body)
        log("[coverage_pr_comment] updated coverage comment ##{existing.id} on #{repo_slug}##{pr_number}")
      else
        client.add_issue_comment(repo_slug, pr_number, body)
        log("[coverage_pr_comment] posted coverage comment on #{repo_slug}##{pr_number}")
      end
    end

    def find_existing_coverage_comment(client, repo_slug, pr_number)
      client.pr_issue_comments(repo_slug, pr_number).find do |comment|
        comment.body.to_s.include?(Coverage::PrCommentFormatter::MARKER)
      end
    rescue => e
      log("[coverage_pr_comment] failed to list PR comments: #{e.class}: #{e.message} — will post new comment")
      nil
    end
  end
end
