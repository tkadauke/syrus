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

    manually_paused = @open_children.select(&:manual_paused?)
    return "child Jobs manually paused: #{label(manually_paused)}" if manually_paused.any?

    attention_holds = @open_children.select(&:landing_attention?)
    return "child Jobs requiring attention before landing: #{label(attention_holds)}" if attention_holds.any?

    nil
  end

  def partitions = [ [ nil, @open_children ] ]

  # Deliberately uncapped: `AppSetting.merge_train_max_size` does not apply to
  # an Epic.
  #
  # That cap bounds how many *unrelated* Jobs a job bundle rebases on top of
  # one another, where every added member is another independent change the
  # others have never been tested against and another chance the train breaks.
  # An Epic's children are not unrelated: they are built as a linear stack,
  # each one already written and graded on top of its predecessor, which is
  # the arrangement the cap exists to approximate. Bounding them protects
  # against a risk the stack has already removed.
  #
  # And an Epic lands all-or-nothing, so a cap here cannot shrink a bundle the
  # way `Scopes::PriorityTier` does -- it can only refuse the Epic outright
  # and leave every child waiting on an operator to raise a number or split
  # the Epic by hand.
  def finalize(ordered)
    LandingBundleAssembler::Scopes::Outcome.new(reason: nil, members: ordered)
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
