# Epic-backed scope for LandingBundleAssembler: readiness policy =
# whole_epic, every OPEN child must be approved, so the Epic lands
# all-or-nothing. A child already closed/merged (landed in a prior train or
# individually) is excluded from the member set but does not block
# readiness. Formerly MergeTrainAssembler.
class LandingBundleAssembler::Scopes::Epic
  def initialize(epic)
    @epic = epic
  end

  # Callers reach this from several directions (the dispatcher, the landing
  # prefetcher, the stuck-Job explainer) and one of them used to pass nil,
  # which crashed the whole landing attempt with a NoMethodError instead of
  # reporting that there was nothing to assemble. "No Epic" is a legitimate
  # not-ready answer, not an exception.
  def blocking_reason
    return "no Epic to assemble" if @epic.nil?

    @open_children = @epic.work_jobs.where.not(state: "closed").to_a
    return "epic has no open child Jobs" if @open_children.empty?

    missing_pr = @open_children.reject { |job| job.pr_number.present? }
    return "child Jobs without a PR: #{label(missing_pr)}" if missing_pr.any?

    unapproved = @open_children.reject(&:approved?)
    return "child Jobs not yet approved: #{label(unapproved)}" if unapproved.any?

    nil
  end

  def partitions = [ [ nil, @open_children ] ]

  def finalize(ordered)
    max = AppSetting.merge_train_max_size
    if ordered.size > max
      LandingBundleAssembler::Scopes::Outcome.new(
        reason: "epic has #{ordered.size} ready children (> merge_train_max_size=#{max}); cannot land atomically",
        members: []
      )
    else
      LandingBundleAssembler::Scopes::Outcome.new(reason: nil, members: ordered)
    end
  end

  # No minimum beyond "at least one open child," already guaranteed by
  # #blocking_reason.
  def min_bundle_size = 1

  def empty_reason = "epic has no open child Jobs"

  private

  def label(jobs)
    jobs.map(&:slug).join(", ")
  end
end
