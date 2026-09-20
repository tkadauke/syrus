class Job::ApprovalUnapprover
  Result = Data.define(:review_id, :github_result) do
    def message = github_result&.message
  end

  def self.call(job:, user:)
    return Result.new(review_id: nil, github_result: nil) unless job.may_unapprove?

    review_id = job.approval_evidence&.dig("github_review_id")
    job.unapprove!
    github_result = Job::ApprovalPropagator.dismiss(job, review_id, user: user)

    Result.new(review_id: review_id, github_result: github_result)
  end
end
