# Handles the transition from fork review PR approval to upstream PR creation.
#
# Called by PollForkReviewPrJob when the fork review PR is either:
#   - approved via a GitHub review
#   - merged on GitHub (treated as accidental merge / implicit approval)
#   - approved via the Syrus UI (future: operator clicks Approve on the Job)
#
# Steps:
#   1. Close the fork review PR unless it was already merged.
#   2. Open an upstream PR from the feature branch against the target repository.
#   3. Save pr_number and pr_repository_id on the Job so normal polling takes over.
#   4. For repositories with a self review policy, immediately record the github
#      review approval so the job is eligible for auto-merge. For two_person and
#      final_say policies the upstream PR requires additional reviews first.
class ForkReviewApprover
  def initialize(job, fork_client:)
    @job = job
    @fork_client = fork_client
  end

  # review_url: the URL of the review or merged PR on the fork; stored as evidence.
  # reviewer_github_handle: GitHub login of the approver (used to link to a Syrus user).
  # fork_pr_merged: true when the fork PR was already merged (skip close step).
  def call(review_url:, reviewer_github_handle: nil, fork_pr_merged: false)
    return if @job.pr_number.present?  # idempotent: upstream PR already exists

    close_fork_review_pr! unless fork_pr_merged
    open_upstream_pr!
    record_approval!(review_url: review_url, reviewer_github_handle: reviewer_github_handle)
  end

  private

  def close_fork_review_pr!
    return unless @job.fork_review_pr_number.present?

    @fork_client.close_pull_request(@job.repository.slug, @job.fork_review_pr_number)
    Rails.logger.info("[ForkReviewApprover] #{@job.slug}: closed fork review PR ##{@job.fork_review_pr_number}")
  rescue => e
    Rails.logger.warn("[ForkReviewApprover] #{@job.slug}: could not close fork review PR — #{e.message}")
  end

  def open_upstream_pr!
    target_repo = @job.target_repository
    upstream_client = GithubClient.for(repository: target_repo, user: @job.user)

    title, body = upstream_pr_copy
    pr_number = PullRequestOpener.new(
      target_repo,
      client: upstream_client,
      head_repository: @job.repository
    ).open(
      branch: @job.branch_name,
      title: title,
      body: body
    )

    @job.update!(pr_number: pr_number, pr_repository_id: target_repo.id)
    Rails.logger.info("[ForkReviewApprover] #{@job.slug}: opened upstream PR ##{pr_number} on #{target_repo.slug}")
  end

  def record_approval!(review_url:, reviewer_github_handle: nil)
    if self_review_policy?
      @job.record_github_review_approval!(review_url: review_url, approved_at: Time.current)
    elsif multi_person_review_policy?
      record_fork_review_job_approval!(reviewer_github_handle: reviewer_github_handle)
    end
  end

  # For two_person / final_say policies, record the fork PR approver as a JobApproval.
  # This counts as the "first approval" in the review chain; subsequent reviews on the
  # upstream PR will add additional JobApprovals via PollPullRequestJob.
  def record_fork_review_job_approval!(reviewer_github_handle:)
    approver = find_syrus_user(reviewer_github_handle) || @job.owner_user || @job.user
    return unless approver

    @job.job_approvals.find_or_create_by!(user: approver)
    Rails.logger.info("[ForkReviewApprover] #{@job.slug}: recorded fork review approval for user #{approver.id} (multi-person policy)")
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    # Already recorded; idempotent.
  end

  def find_syrus_user(github_handle)
    return nil unless github_handle.present?

    User.where("LOWER(github_handle) = ?", github_handle.downcase).first
  end

  def self_review_policy?
    @job.repository.review_policy == "self"
  end

  def multi_person_review_policy?
    @job.repository.review_policy.in?(%w[ two_person final_say ])
  end

  def upstream_pr_copy
    workflow = @job.workflows.where(state: "succeeded").order(:created_at).last
    title = workflow&.artifact("pr_title").presence || fallback_title
    body  = workflow&.artifact("pr_body").presence  || fallback_body
    [ title, upstream_pr_body(body) ]
  end

  def upstream_pr_body(base_body)
    parts = []
    parts << base_body
    parts << ""
    parts << "---"
    parts << "_Reviewed via fork staging PR #{@job.repository.slug}##{@job.fork_review_pr_number}. Review carefully._"
    parts.join("\n")
  end

  def fallback_title
    "[syrus] #{@job.repository.slug}##{@job.issue_number}"
  end

  def fallback_body
    "Opened by Syrus following fork review approval.\n\nReview the diff carefully — this PR was authored by an LLM."
  end
end
