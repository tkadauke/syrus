# Who instance-owned work runs as (workflow-engine-v3 C4).
#
# `PollMainBranchHealthJob` and `MainHealthChangedService` resolve credentials
# through `repository.user`, which is `optional: true`. Grading main is not
# that person's work -- it is the instance's -- and borrowing their identity
# means their departure, their revoked token, or a nil owner silently stops
# instance-wide health checks.
#
# This does not yet change who the work runs as. It names the question and
# reports when the answer is a borrowed identity, which is the part that has to
# exist before anything can be migrated onto a real instance principal: right
# now nothing can even tell you how much infrastructure work is running on
# someone's personal credentials.
module InstanceIdentity
  # Work that belongs to the instance rather than to whoever happens to own the
  # repository row.
  INFRASTRUCTURE_TRIGGER_KINDS = %w[main_grader main_branch_repair agent_insight deploy].freeze

  Resolution = Data.define(:user, :source) do
    # True when instance work is running on a person's credentials.
    def borrowed? = source == "repository_owner"
    def missing? = user.nil?
  end

  def self.infrastructure?(trigger_kind) = INFRASTRUCTURE_TRIGGER_KINDS.include?(trigger_kind.to_s)

  # Resolves the identity instance-owned work should use for `repository`.
  #
  # Today that is still the repository owner, reported as borrowed so the
  # instrumentation is honest about it. A dedicated instance principal slots in
  # here without every caller changing.
  def self.for_repository(repository)
    owner = repository&.user
    return Resolution.new(user: nil, source: "none") if owner.nil?

    Resolution.new(user: owner, source: "repository_owner")
  end

  # Counts repositories whose infrastructure work has no identity at all --
  # `repository.user` is nil, so main-branch health silently does not run.
  # This is the number that says whether an instance principal is overdue.
  def self.repositories_without_identity
    Repository.where(user_id: nil)
  end
end
