class LandingValidationPrefetcher
  ARTIFACT_WORKFLOW_ID = "landing_validation_prefetch_workflow_id".freeze
  ARTIFACT_DISPATCHED_AT = "landing_validation_prefetch_dispatched_at".freeze
  SOURCE_TRIGGER_KINDS = %w[auto_merge merge_train].freeze
  VALIDATION_TRIGGER_KINDS = %w[landing_validation merge_train_validation].freeze

  def self.after_landing_graders_passed(workflow:)
    new(workflow).call
  end

  def initialize(workflow, git: GitRunner.new)
    @workflow = workflow
    @job = workflow.job
    @git = git
  end

  def call
    return unless Feature.landing_validation_prefetch_enabled?
    return unless workflow.trigger_kind.in?(SOURCE_TRIGGER_KINDS)
    return if workflow.artifact(ARTIFACT_WORKFLOW_ID).present?
    return unless job&.landing?

    target = next_landing_unit
    return unless target

    source = source_identity
    return unless source
    artifacts = source.merge(target.artifacts)

    workflow_to_start = nil
    Workflow.transaction do
      workflow.lock!
      target.jobs.each(&:lock!)
      if workflow.artifact(ARTIFACT_WORKFLOW_ID).blank? && target.still_eligible?
        workflow_to_start = target.instantiate(artifacts)
        workflow.set_artifact!(ARTIFACT_WORKFLOW_ID, workflow_to_start.id)
        workflow.set_artifact!(ARTIFACT_DISPATCHED_AT, Time.current.iso8601)
      end
    end

    StepDispatcher.start_workflow(workflow_to_start) if workflow_to_start
    workflow_to_start
  rescue StandardError => e
    Rails.logger.warn("[LandingValidationPrefetcher] prefetch dispatch failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
    nil
  end

  private

  attr_reader :workflow, :job, :git

  TargetUnit = Data.define(:kind, :key, :jobs, :artifacts) do
    def instantiate(seed_artifacts)
      workflow_class.instantiate(job: workflow_job, artifacts: seed_artifacts.merge(artifacts))
    end

    def still_eligible?
      case kind
      when "job"
        job = jobs.first
        job.approved? &&
          !job.external_pr? &&
          job.pr_number.present? &&
          !job.workflows.active.where(trigger_kind: VALIDATION_TRIGGER_KINDS).exists?
      when "merge_train"
        jobs.all?(&:approved?) &&
          jobs.all? { |job| job.pr_number.present? && job.branch_name.present? } &&
          !Workflow.active.where(job_id: jobs.map(&:id), trigger_kind: %w[merge_train merge_train_validation]).exists?
      else
        false
      end
    end

    private

    def workflow_class
      kind == "merge_train" ? Workflows::MergeTrainValidation : Workflows::LandingValidation
    end

    def workflow_job
      jobs.last
    end
  end

  def next_landing_unit
    units = LandingQueueProcessor.landing_units(Job.where(repository_id: job.repository_id))
    index = units.index { |unit| unit.key == source_unit_key }
    return if index.nil?

    units[(index + 1)..]&.filter_map { |unit| target_for(unit) }&.first
  end

  def source_unit_key
    job.epic_id.present? ? "epic:#{job.epic_id}" : "job:#{job.id}"
  end

  def target_for(unit)
    return if unit.blocker_jobs.any?

    if merge_train_unit?(unit) && AppSetting.merge_train_enabled?
      merge_train_target(unit)
    else
      ordinary_target(unit)
    end
  end

  def ordinary_target(unit)
    candidate = unit.jobs.find { |unit_job| ordinary_auto_merge_candidate?(unit_job) }
    return unless candidate

    TargetUnit.new(
      kind: "job",
      key: unit.key,
      jobs: [ candidate ],
      artifacts: candidate_identity(candidate).merge(
        "prefetch_landing_unit_key" => unit.key,
        "prefetch_landing_unit_kind" => "job"
      )
    )
  end

  def merge_train_target(unit)
    return unless AppSetting.merge_train_enabled?
    return unless unit.jobs.map(&:epic_id).compact.uniq.one?
    return unless unit.jobs.all? { |member| ordinary_merge_train_member?(member) }
    return if Workflow.active.where(job_id: unit.job_ids, trigger_kind: %w[merge_train merge_train_validation]).exists?

    result = MergeTrainAssembler.call(unit.jobs.first.epic)
    return unless result.ready?
    return unless result.job_ids == unit.job_ids

    TargetUnit.new(
      kind: "merge_train",
      key: unit.key,
      jobs: result.members,
      artifacts: {
        "prefetch_landing_unit_key" => unit.key,
        "prefetch_landing_unit_kind" => "merge_train",
        "prefetch_merge_train_epic_id" => result.members.first.epic_id,
        "prefetch_merge_train_member_job_ids" => result.job_ids,
        "predicted_base_ref" => result.members.first.repository.default_branch
      }
    )
  end

  def merge_train_unit?(unit)
    unit.key.start_with?("epic:")
  end

  def ordinary_auto_merge_candidate?(candidate)
    ordinary_merge_candidate?(candidate) &&
      !(candidate.epic_id.present? && AppSetting.merge_train_enabled?) &&
      !candidate.workflows.active.where(trigger_kind: VALIDATION_TRIGGER_KINDS).exists?
  end

  def ordinary_merge_train_member?(candidate)
    ordinary_merge_candidate?(candidate) &&
      candidate.epic_id.present? &&
      !candidate.workflows.active.where(trigger_kind: VALIDATION_TRIGGER_KINDS).exists?
  end

  def ordinary_merge_candidate?(candidate)
    candidate.approved? &&
      !candidate.external_pr? &&
      candidate.pr_number.present? &&
      candidate.branch_name.present?
  end

  def source_identity
    path = WorkflowWorkspace.path_for(workflow)
    return unless path.exist?

    head_sha = git.run("rev-parse", "HEAD", chdir: path.to_s).strip.presence
    tree_sha = git.run("rev-parse", "HEAD^{tree}", chdir: path.to_s).strip.presence
    return if head_sha.blank? || tree_sha.blank?

    {
      "prefetch_source_workflow_id" => workflow.id,
      "prefetch_source_job_id" => job.id,
      "prefetch_source_workspace_path" => path.to_s,
      "prefetch_source_head_sha" => head_sha,
      "prefetch_source_tree_sha" => tree_sha,
      "predicted_base_sha" => head_sha,
      "predicted_base_tree_sha" => tree_sha,
      "predicted_base_ref" => predicted_base_ref
    }
  rescue StandardError => e
    Rails.logger.warn("[LandingValidationPrefetcher] source identity failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
    nil
  end

  def predicted_base_ref
    return merge_train_base_ref if workflow.trigger_kind == "merge_train"

    job.effective_base_branch.presence || job.repository.default_branch
  end

  def merge_train_base_ref
    train_id = workflow.artifact("merge_train_id")
    return job.repository.default_branch if train_id.blank?

    MergeTrain.find_by(id: train_id)&.base_branch.presence || job.repository.default_branch
  end

  def candidate_identity(candidate)
    pr_repo = candidate.effective_pr_repository
    client = GithubClient.for(repository: pr_repo, user: candidate.user)
    pr = client.pull_request(pr_repo.slug, candidate.pr_number, bypass_cache: true)

    {
      "prefetch_candidate_pr_number" => candidate.pr_number,
      "prefetch_candidate_head_sha" => MergeabilityRecorder.head_sha(pr),
      "prefetch_candidate_base_ref" => MergeabilityRecorder.base_ref(pr)
    }.compact
  rescue StandardError => e
    Rails.logger.warn("[LandingValidationPrefetcher] candidate identity failed for #{candidate.slug}: #{e.class}: #{e.message}")
    {}
  end
end
