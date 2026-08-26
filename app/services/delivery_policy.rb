# Answers delivery-model questions (target branch, grade phase, promotion/
# hotfix-sync posture) for a repository/job, per
# docs/plans/delivery-tracks-and-promotion.md. Workflow code should ask this
# object questions instead of reading `.syrus.yml`'s `delivery:` block or
# repository columns directly (see "Policy Objects" in the plan).
#
# `Job#delivery_track` selects a track by name; a blank/unset value, or a
# name that doesn't match any configured track, resolves to the config's
# `default` track (see `track_for`). `JobStackBase#effective_base_branch`
# calls `job_landing_branch` for its final fallback once `target_branch` and
# stack/dependency resolution are exhausted.
class DeliveryPolicy
  def self.for(repository:, job: nil)
    new(repository: repository, job: job)
  end

  def initialize(repository:, job: nil)
    @repository = repository
    @job = job
  end

  def job_delivery_track(job = @job)
    track_for(job).name
  end

  def job_landing_branch(job = @job)
    resolved_branch(track_for(job))
  end

  def review_grade_phase(job = @job)
    track_for(job).review_grade_phase
  end

  def landing_grade_phase(job = @job)
    track_for(job).landing_grade_phase
  end

  def branch_health_grade_phase(branch = nil)
    track_for_branch(branch).branch_health_grade_phase
  end

  def promotion_enabled?
    delivery.promotion.enabled
  end

  def promotion_mode
    delivery.promotion.mode
  end

  # The skill name (`delivery.promotion.repair_skill`) a promotion
  # ref-movement workflow should invoke — via the same `Skills.for`
  # resolution `Steps::RunSkill` uses — when the deterministic merge attempt
  # conflicts or the `promotion` grade phase fails. `nil` when unconfigured;
  # `Steps::PromotionRepair` fails the step rather than guessing a skill.
  def promotion_repair_skill
    delivery.promotion.repair_skill
  end

  # First-iteration source/target resolution for the promotion ref-movement
  # workflow (docs/plans/delivery-tracks-and-promotion.md Story 2): the
  # `default` delivery track's branch promotes into the repository's actual
  # GitHub default branch. `delivery.promotion` has no explicit source/target
  # track fields yet (a later Story's `from`/`to` config) — until then this is
  # the one meaningful reading of "promote the track I develop on into the
  # branch GitHub treats as canonical."
  def promotion_source_branch
    resolved_branch(default_track)
  end

  def promotion_target_branch
    repository.default_branch
  end

  def hotfix_sync_enabled?
    delivery.hotfix_sync.enabled
  end

  def hotfix_sync_mode
    delivery.hotfix_sync.mode
  end

  def upstream_export_enabled?
    delivery.upstream_export.enabled
  end

  def upstream_export_mode
    delivery.upstream_export.mode
  end

  # Story 7 (owner + peer local approval). When the repository's
  # `.syrus.yml` has no `approval:` block at all, falls back to the job's
  # existing `ReviewPolicies::REGISTRY` policy (`self`/`two_person`/
  # `final_say`) so repositories that haven't opted into the new config
  # keep their current approval behavior unchanged. Once `approval.job` is
  # configured, a peer's approval only counts toward `peer_count` when that
  # peer has repository access on this Syrus instance (a `RepositoryMembership`
  # row) — an approval from someone who has since lost access doesn't count.
  # Whether this repository has opted into the Story 7 `approval:` block at
  # all. Callers that need to decide between "enforce the configured
  # owner/peer policy" and "fall back to legacy behavior" (rather than just
  # calling `job_approval_satisfied?`, which already degrades gracefully)
  # use this to change bypass semantics around jobs with no `job_approvals`
  # rows — see `LandingQueueProcessor#landing_approval_satisfied?`.
  def approval_configured?
    config.approval.present?
  end

  def job_approval_satisfied?(job = @job)
    return job.approval_satisfied? if config.approval.nil?

    job_approval = config.approval.job
    owner_required = job_approval&.owner_required
    owner_required = true if owner_required.nil?
    required_peer_count = job_approval&.peer_count || 0

    return false if owner_required && !owner_approved?(job)

    eligible_peer_approval_count(job) >= required_peer_count
  end

  # Whether landing a promotion ref-movement should be gated on an explicit
  # operator (maintainer) approval rather than proceeding automatically once
  # its own grade phases are green. Falls back to the existing
  # `delivery.promotion.approval_required` flag when `approval.promotion` is
  # not configured, so this is additive to the config parsed in the prior
  # Job, not a replacement for it. Not wired into any landing gate yet — see
  # `landing-queue-track-approval-gating`.
  def requires_operator_approval_for_promotion?
    maintainer_count = config.approval&.promotion&.maintainer_count
    return delivery.promotion.approval_required if maintainer_count.nil?

    maintainer_count.positive?
  end

  private

  def owner_approved?(job)
    job.job_approvals.where(user_id: effective_owner_id(job)).exists?
  end

  # Counts distinct peer approvers (not the job's owner) who currently have
  # repository access on this Syrus instance. Reuses the same
  # `RepositoryMembership` existence check `ChatAttachment` uses for access
  # gating rather than inventing a new one.
  def eligible_peer_approval_count(job)
    peer_user_ids = job.job_approvals.where.not(user_id: effective_owner_id(job)).distinct.pluck(:user_id)
    return 0 if peer_user_ids.empty?

    repository.repository_memberships.where(user_id: peer_user_ids).distinct.count(:user_id)
  end

  def effective_owner_id(job)
    job.owner_user_id.presence || job.user_id
  end

  attr_reader :repository

  def track_for(job)
    return default_track if job.nil?

    name = job.delivery_track.presence
    return default_track if name.blank?

    delivery.tracks[name] || default_track
  end

  def track_for_branch(branch)
    return default_track if branch.blank?

    delivery.tracks.values.find { |track| resolved_branch(track) == branch } || default_track
  end

  def default_track
    delivery.tracks.fetch(SyrusYml::DEFAULT_DELIVERY_TRACK_NAME)
  end

  def resolved_branch(track)
    track.branch.presence || repository.default_branch
  end

  def delivery
    @delivery ||= config.delivery
  end

  def config
    @config ||= load_config
  end

  def load_config
    clone_path = RepositoryBareClone.path_for(repository)
    return blank_config unless clone_path.directory?

    yml_content = `git --git-dir #{clone_path.to_s.shellescape} show HEAD:.syrus.yml 2>/dev/null`
    return blank_config unless $?.success? && yml_content.present?

    SyrusYml.new(yml_content).parse
  rescue StandardError
    blank_config
  end

  def blank_config
    SyrusYml.new("").parse
  end
end
