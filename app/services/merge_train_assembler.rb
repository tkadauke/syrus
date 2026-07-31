# Decides whether an Epic is ready to land as a single atomic
# merge-train, and returns its members in dependency (topological)
# order. Pure logic — no side effects. See
# docs/plans/landing-merge-train.md.
#
# Readiness policy = whole_epic: every OPEN child must be approved, so
# the Epic lands all-or-nothing. A child already closed/merged (landed
# in a prior train or individually) is excluded from the member set but
# does not block readiness.
class MergeTrainAssembler
  Result = Data.define(:ready, :reason, :members) do
    def ready? = ready
    def job_ids = members.map(&:id)
  end

  def self.call(epic) = new(epic).call

  def initialize(epic)
    @epic = epic
  end

  def call
    open_children = @epic.work_jobs.where.not(state: "closed").to_a
    return not_ready("epic has no open child Jobs") if open_children.empty?

    missing_pr = open_children.reject { |job| job.pr_number.present? }
    return not_ready("child Jobs without a PR: #{label(missing_pr)}") if missing_pr.any?

    unapproved = open_children.reject(&:approved?)
    return not_ready("child Jobs not yet approved: #{label(unapproved)}") if unapproved.any?

    members = LandingQueueProcessor.dependency_ordered(open_children)

    max = AppSetting.merge_train_max_size
    if members.size > max
      return not_ready("epic has #{members.size} ready children (> merge_train_max_size=#{max}); cannot land atomically")
    end

    Result.new(ready: true, reason: nil, members: members)
  end

  private

  def not_ready(reason)
    Result.new(ready: false, reason: reason, members: [])
  end

  def label(jobs)
    jobs.map(&:slug).join(", ")
  end
end
