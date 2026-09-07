# Epic-backed scope for LandingRetrier. Reapproval candidates are every
# implemented Job under the Epic (not limited to the failed train's
# members -- an Epic can gain approved-but-never-landed children between
# train attempts). Recovery of genuinely-failed members only applies when
# rebuilding from a specific failed train; the bulk "Retry landing" action
# (#call) has no source train and recovers nothing. Formerly
# EpicLandingRetrier.
class LandingRetrier::Scopes::Epic
  attr_reader :by_user

  def initialize(epic, by_user: nil, source_train: nil)
    @epic = epic
    @by_user = by_user
    @source_train = source_train
  end

  def reapproval_candidates = @epic.jobs.where(state: "implemented").order(:id)

  def recoverable_members
    return [] unless @source_train

    @source_train.members.includes(:job).map(&:job)
  end

  def dispatch! = MergeTrainDispatcher.try_dispatch!(@epic, bypass_cooldown: true)
end
