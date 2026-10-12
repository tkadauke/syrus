class MergeTrainFailurePolicy
  SELECTED_RUNG_ARTIFACT = "merge_train_failure_policy_rung".freeze

  IMPLEMENTED_RUNG_CLASSES = [
    Rungs::Restart,
    Rungs::KeepAssembly,
    Rungs::KeepFixes
  ].freeze
  IMPLEMENTED_RUNGS = IMPLEMENTED_RUNG_CLASSES.index_by(&:name).freeze

  def self.resolve(repository:, attempt_number:, retry_classification:)
    new(repository: repository, attempt_number: attempt_number, retry_classification: retry_classification).resolve
  end

  def self.resolve_for_workflow(workflow)
    run = failed_run_for(workflow)
    resolve(
      repository: workflow&.job&.repository,
      attempt_number: attempt_number_for(workflow, failed_run: run),
      retry_classification: retry_classification_for(failed_run: run)
    )
  end

  def self.selected_rung_for_workflow(workflow)
    workflow&.artifact(SELECTED_RUNG_ARTIFACT).to_s.presence
  end

  def self.failed_run_for(workflow)
    return unless workflow

    Run.joins(:step)
       .where(steps: { workflow_id: workflow.id })
       .where(state: "failed")
       .order(id: :desc)
       .includes(:run_failure_classification)
       .first
  end

  def self.attempt_number_for(workflow, failed_run: nil)
    run = failed_run || failed_run_for(workflow)
    return 1 unless run

    AutoRetryAttempt.budget_scope_for(
      job: run.job,
      agent_provider: run.agent_provider.presence || run.workflow&.agent_provider,
      failure_classification: retry_classification_for(failed_run: run)
    ).count + 1
  end

  def self.retry_classification_for(failed_run:)
    failed_run&.run_failure_classification&.classification ||
      failed_run&.agent_outcome.to_s.presence ||
      "unknown"
  end

  def initialize(repository:, attempt_number:, retry_classification:)
    @repository = repository
    @attempt_number = attempt_number.to_i
    @retry_classification = retry_classification.to_s.presence || "unknown"
  end

  def resolve
    return Rungs::Restart.new unless config_determined?
    return instance_default_rung unless configured_ladder?
    return Rungs::Restart.new if @attempt_number < 1 || @attempt_number > retry_budget_limit

    rung_names = ladder.drop(@attempt_number - 1).first(retry_budget_limit - @attempt_number + 1)
    rung_names.each do |name|
      rung_class = IMPLEMENTED_RUNGS[name.to_s]
      return rung_class.new if rung_class
    end

    Rungs::Restart.new
  end

  private

  def instance_default_rung
    IMPLEMENTED_RUNGS.fetch(AppSetting.merge_train_failure_policy).new
  end

  def configured_ladder?
    ladder.present?
  end

  def config_determined?
    loaded_syrus_yml.determined?
  end

  def ladder
    return @ladder if defined?(@ladder)

    @ladder = loaded_syrus_yml.config&.merge_train&.failure_policy.presence
  end

  def retry_budget_limit
    AutoRetryAttempt.retry_budget_limit_for(@retry_classification)
  end

  def loaded_syrus_yml
    return @loaded_syrus_yml if defined?(@loaded_syrus_yml)

    @loaded_syrus_yml = load_syrus_yml
  end

  def load_syrus_yml
    return RepoDefaultBranchSyrusYml::Result.new(config: nil, source: "none", note: "no repository", outcome: :absent) unless @repository

    RepoDefaultBranchSyrusYml.new(repository: @repository, user: @repository.user).resolve
  end
end
