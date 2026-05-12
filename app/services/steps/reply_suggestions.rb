module Steps
  # Posts the short "applied" acknowledgement after the push step has
  # succeeded, so the review thread points at a commit that is already
  # on the PR branch.
  class ReplySuggestions < Base
    def call
      applied = Array(workflow.artifact("applied_suggestions"))
      return log("reply_suggestions: no auto-applied suggestions to acknowledge") if applied.empty?

      client = GithubClient.for(repository: repository, user: job.user)
      applied.each do |suggestion|
        comment_id = suggestion["comment_id"]
        next if comment_id.blank?
        sha = suggestion["commit_sha"].to_s
        client.reply_to_pr_review_comment(
          repository.slug,
          job.pr_number,
          comment_id,
          "Applied suggested change in #{sha[0, 7]}."
        )
      end

      log("reply_suggestions: acknowledged #{applied.size} auto-applied suggestion(s)")
    end
  end
end
