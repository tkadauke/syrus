# Comments on and closes a merge-train member's GitHub PR once its Job has
# landed. Shared by the happy path (Steps::MergeTrainLand, landing through an
# integration PR merge) and MergeTrainFailureHandler's already-landed self-heal
# (no integration PR -- the member's commits reached base through an earlier
# attempt, before the workflow that just failed could reach this step).
class MergeTrainMemberPrReconciler
  def self.call(...) = new(...).call

  def initialize(client:, repository:, train:, member_job:, integration_pr: nil, log: nil)
    @client = client
    @repository = repository
    @train = train
    @member_job = member_job
    @integration_pr = integration_pr
    @log = log
  end

  def call
    return if member_job.pr_number.blank?

    cleanup("comment on PR ##{member_job.pr_number}") do
      client.add_issue_comment(repository.slug, member_job.pr_number, landed_comment)
    end
    cleanup("close PR ##{member_job.pr_number}") do
      client.close_pull_request(repository.slug, member_job.pr_number)
    end
  end

  private

  attr_reader :client, :repository, :train, :member_job, :integration_pr

  def landed_comment
    via = integration_pr ? " (integration PR ##{integration_pr.number})" : ""
    "Landed via #{train.label} merge-train#{via}. #{member_job.slug}."
  end

  def cleanup(description)
    yield
    true
  rescue Octokit::TooManyRequests, Octokit::Error => e
    @log&.call("merge_train: cleanup could not #{description}: #{e.class}: #{e.message}", kind: "system")
    false
  end
end
