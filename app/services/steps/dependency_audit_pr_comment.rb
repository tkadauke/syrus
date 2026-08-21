module Steps
  # Non-agentic step that posts or updates the dependency-audit comment on
  # an existing PR. Inserted after dependency_audit in subsequent-workflow
  # chains (pr_comment, chat_feedback) where the PR already exists. For
  # initial workflows the same posting logic lives in Steps::PrOpen, which
  # already has the PR number in hand.
  #
  # No-ops gracefully when:
  #   - no lockfile changed, or every scanned ecosystem came back clean
  #     (dependency_audit artifact has no pr_comment_body)
  #   - the Job has no PR yet (shouldn't happen here, but safe to guard)
  class DependencyAuditPrComment < Base
    def call
      pr_comment_body = workflow.artifact("dependency_audit")&.[]("pr_comment_body")

      unless pr_comment_body.present?
        log("[dependency_audit_pr_comment] no PR comment body in dependency_audit artifact — skipping")
        return
      end

      pr_number = job.pr_number
      unless pr_number.present?
        log("[dependency_audit_pr_comment] no PR number for job — skipping")
        return
      end

      pr_repo   = job.effective_pr_repository
      client    = GithubClient.for(repository: pr_repo, user: job.user)
      repo_slug = pr_repo.slug

      upsert_dependency_audit_comment(client, repo_slug, pr_number, pr_comment_body)
    end

    private

    def upsert_dependency_audit_comment(client, repo_slug, pr_number, body)
      existing = find_existing_dependency_audit_comment(client, repo_slug, pr_number)

      if existing
        client.update_issue_comment(repo_slug, existing.id, body)
        log("[dependency_audit_pr_comment] updated dependency audit comment ##{existing.id} on #{repo_slug}##{pr_number}")
      else
        client.add_issue_comment(repo_slug, pr_number, body)
        log("[dependency_audit_pr_comment] posted dependency audit comment on #{repo_slug}##{pr_number}")
      end
    end

    def find_existing_dependency_audit_comment(client, repo_slug, pr_number)
      client.pr_issue_comments(repo_slug, pr_number).find do |comment|
        comment.body.to_s.include?(DependencyAuditReport::PrCommentFormatter::MARKER)
      end
    rescue => e
      log("[dependency_audit_pr_comment] failed to list PR comments: #{e.class}: #{e.message} — will post new comment")
      nil
    end
  end
end
