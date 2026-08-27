# Derives a Job's apparent delivery status — a UI-facing summary computed
# from concrete delivery facts (`job.delivery_track`, `DeliveryPolicy`
# answers, and `JobPrLink` rows) instead of a new AASM state, per
# docs/plans/delivery-tracks-and-promotion.md's "Job Lifecycle And Delivery
# Status" section. `Job#state` stays the source of truth for what Syrus is
# actually doing; this only summarizes where the work currently sits for the
# delivery-status UI later in this Epic.
#
# Promotion, hotfix-sync, and upstream-export ref-movement workflows don't
# exist yet (they land in later Jobs of this Epic), so a repository with
# none of `delivery.promotion`/`delivery.hotfix_sync`/`delivery.upstream_export`
# configured — today's default for every repository — only ever resolves to
# `waiting_for_local_approval` or `approved_for_local_landing`, matching
# current behavior exactly. The other statuses become reachable once those
# later Jobs start writing `promotion`/`upstream_export`-role `JobPrLink`
# rows (and, on them, a `metadata["pr_state"]` of `"open"`/`"merged"`/
# `"closed"` — the free-form classification slot `JobPrLink#metadata` is
# reserved for).
class DeliveryStatus
  STATUSES = %i[
    waiting_for_local_approval
    approved_for_local_landing
    waiting_for_upstream_approval
    waiting_for_promotion
    syncing_hotfix
    upstream_merged
    upstream_closed_without_merge
    delivery_needs_attention
  ].freeze

  def self.for(job:, policy: nil)
    new(job: job, policy: policy).status
  end

  def initialize(job:, policy: nil)
    @job = job
    @policy = policy || DeliveryPolicy.for(repository: job.repository, job: job)
  end

  def status
    return :delivery_needs_attention if job.failed?
    return :upstream_closed_without_merge if upstream_link_closed_without_merge?
    return :upstream_merged if upstream_link_merged?
    return :waiting_for_upstream_approval if upstream_link_pending?
    return :delivery_needs_attention if unsuccessful_local_closure?
    return :syncing_hotfix if syncing_hotfix?
    return :waiting_for_promotion if waiting_for_promotion?
    return :approved_for_local_landing if locally_approved_or_landed?

    :waiting_for_local_approval
  end

  private

  attr_reader :job, :policy

  # A Job the operator has to look at that isn't better explained by one of
  # the more specific statuses below: an unsuccessful closure (preempted,
  # too many failures, an ingested external PR closed without merging).
  def unsuccessful_local_closure?
    job.closed? && job.closure_reason.present? && Job::SUCCESSFUL_CLOSURE_REASONS.exclude?(job.closure_reason)
  end

  # The PR link that governs this Job's delivery beyond local landing: the
  # promotion PR when the repository promotes a local track upward, else the
  # upstream-export PR for a fork sending work to its in-instance upstream.
  # Configuring both is an unusual repository (promotion and upstream-export
  # solve different topologies), so promotion wins the tie deterministically.
  def upstream_role
    return JobPrLink::ROLE_PROMOTION if policy.promotion_enabled?
    JobPrLink::ROLE_UPSTREAM_EXPORT if policy.upstream_export_enabled?
  end

  def upstream_link
    return @upstream_link if defined?(@upstream_link)

    role = upstream_role
    @upstream_link = role && job.pr_links.find { |link| link.role == role }
  end

  def upstream_link_state
    upstream_link&.metadata&.[]("pr_state")
  end

  def upstream_link_merged?
    upstream_link.present? && upstream_link_state == "merged"
  end

  def upstream_link_closed_without_merge?
    upstream_link.present? && upstream_link_state == "closed"
  end

  def upstream_link_pending?
    upstream_link.present? && !upstream_link_merged? && !upstream_link_closed_without_merge?
  end

  # Hotfix-sync direction is release-branch -> development-branch (see
  # `delivery.hotfix_sync.direction`): once a Job lands on a non-default
  # track and the repository has hotfix-sync configured, the sync-back is
  # presumed pending until a later Job's hotfix-sync workflow can record its
  # own completion fact.
  def syncing_hotfix?
    policy.hotfix_sync_enabled? &&
      policy.job_delivery_track(job) != SyrusYml::DEFAULT_DELIVERY_TRACK_NAME &&
      locally_landed?
  end

  def waiting_for_promotion?
    policy.promotion_enabled? && upstream_link.blank? && locally_landed?
  end

  def locally_landed?
    job.closed? && Job::SUCCESSFUL_CLOSURE_REASONS.include?(job.closure_reason)
  end

  def locally_approved_or_landed?
    job.approved? || job.landing? || locally_landed?
  end
end
