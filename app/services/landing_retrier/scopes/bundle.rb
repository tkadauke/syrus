# Bundle-backed scope for LandingRetrier: epicless MergeTrain rows have no
# Epic, so they cannot use Scopes::Epic's whole-Epic reapproval query --
# both recovery and reapproval are scoped to the source train's own member
# Jobs. Always rebuilds from a specific failed train; there is no bulk
# "Retry landing" entry point for a bundle the way there is for an Epic.
# Formerly JobBundleRetrier.
class LandingRetrier::Scopes::Bundle
  attr_reader :by_user

  def initialize(repository, source_train:, by_user: nil)
    @repository = repository
    @source_train = source_train
    @by_user = by_user
  end

  def reapproval_candidates = member_jobs
  def recoverable_members = member_jobs

  def dispatch! = JobBundleDispatcher.try_dispatch!(@repository, bypass_cooldown: true)

  private

  def member_jobs
    @member_jobs ||= @source_train.members.includes(:job).map(&:job)
  end
end
