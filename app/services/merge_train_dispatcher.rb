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

  def self.try_dispatch!(epic) = new(epic).try_dispatch!

  def initialize(epic)
    @epic = epic
  end

  def try_dispatch!
    return unless AppSetting.merge_train_enabled?
    return if active_train_in_progress?
    return if landing_in_progress?
    return if cooling_down?

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

  private

  def active_train_in_progress?
    MergeTrain.active.where(epic_id: @epic.id).exists? ||
      Workflow.active.where(trigger_kind: "merge_train", job_id: @epic.jobs.select(:id)).exists?
  end

  def landing_in_progress?
    Job.landing.where(repository_id: @epic.repository_id).exists?
  end

  def cooling_down?
    last_failure = MergeTrain.where(epic_id: @epic.id, state: "failed").maximum(:finished_at)
    last_failure.present? && last_failure > RETRY_COOLDOWN.ago
  end
end
