# Dispatches an Epic merge-train: when the Epic is ready (every open
# child approved, within size cap), create the MergeTrain + members,
# lock the member Jobs into :landing (claiming the repo's single landing
# slot), and start the merge_train Workflow on the tip member. Mirrors
# LandingQueueProcessor#land's transactional locking so it races safely
# with the recurring queue tick. See docs/plans/landing-merge-train.md.
class MergeTrainDispatcher
  # After a train fails (e.g. an unresolvable build conflict), don't
  # immediately re-dispatch — fail_landing reverts members to
  # :implemented and PollMergeStateJob may auto-re-approve them, which
  # would otherwise spin a doomed train every tick. Wait out a cooldown
  # so a genuinely-stuck Epic surfaces for an operator instead of
  # churning.
  RETRY_COOLDOWN = 30.minutes

  def self.try_dispatch!(epic, bypass_cooldown: false) = new(epic, bypass_cooldown: bypass_cooldown).try_dispatch!
  def self.blocker_reason(epic, bypass_cooldown: false) = new(epic, bypass_cooldown: bypass_cooldown).blocker_reason

  def initialize(epic, bypass_cooldown: false)
    @epic = epic
    @bypass_cooldown = bypass_cooldown
  end

  def try_dispatch!
    return if blocker_reason

    result = MergeTrainAssembler.call(@epic)
    return unless result.ready?

    workflow = nil
    MergeTrain.transaction do
      members = result.members.map { |job| job.tap(&:lock!) }

      raise ActiveRecord::Rollback if Job.landing.where(repository_id: @epic.repository_id).exists?
      raise ActiveRecord::Rollback unless members.all? { |job| job.approved? && job.may_start_landing? }

      train = MergeTrain.create!(
        epic: @epic,
        repository: @epic.repository,
        base_branch: @epic.repository.default_branch
      )

      members.each_with_index do |job, index|
        job.landing_failure_reason = nil
        job.start_landing!
        job.save!
        MergeTrainMember.create!(merge_train: train, job: job, position: index)
      end

      workflow = Workflows::MergeTrain.instantiate(
        job: members.last,
        artifacts: { "merge_train_id" => train.id }
      )
    end

    return unless workflow

    StepDispatcher.start_workflow(workflow)
    workflow
  end

  def blocker_reason
    return "merge trains are disabled" unless AppSetting.merge_train_enabled?
    return "waiting for Epic to release" unless @epic.releases_jobs_for_execution?
    return "#{@epic.slug} already has an active merge train" if active_train_in_progress?

    if (landing_job = landing_job_in_progress)
      return "#{landing_job.slug} is already landing for #{@epic.repository.slug}"
    end

    if !@bypass_cooldown && (failed_train = cooling_down_failure)
      return cooldown_reason(failed_train)
    end

    readiness = MergeTrainAssembler.call(@epic)
    return readiness.reason unless readiness.ready?

    blockers = landing_unit_blockers_for(readiness.members)
    return "stack dependencies not ready: #{blockers.map(&:slug).join(", ")}" if blockers.any?

    nil
  end

  private

  def active_train_in_progress?
    MergeTrain.active.where(epic_id: @epic.id).exists? ||
      Workflow.active.where(trigger_kind: "merge_train", job_id: @epic.jobs.select(:id)).exists?
  end

  def landing_job_in_progress
    Job.landing.where(repository_id: @epic.repository_id).order(:id).first
  end

  def cooling_down_failure
    MergeTrain
      .where(epic_id: @epic.id, state: "failed")
      .where(
        "failure_reason IS NULL OR (failure_reason NOT LIKE ? AND failure_reason NOT LIKE ?)",
        "merge_train: base moved%",
        "merge_train: missing built base SHA%"
      )
      .where("finished_at > ?", RETRY_COOLDOWN.ago)
      .order(finished_at: :desc)
      .first
  end

  def landing_unit_blockers_for(members)
    unit = LandingQueueProcessor.landing_units(Job.where(id: members.map(&:id))).first
    return [] unless unit

    unit.blocker_jobs
  end

  def cooldown_reason(failed_train)
    remaining_seconds = [ failed_train.finished_at + RETRY_COOLDOWN - Time.current, 0 ].max
    remaining_minutes = (remaining_seconds / 60.0).ceil
    reason = failed_train.failure_reason.to_s.presence || "unclassified failure"
    "recent failed merge train is cooling down for #{remaining_minutes}m: #{reason}"
  end
end
