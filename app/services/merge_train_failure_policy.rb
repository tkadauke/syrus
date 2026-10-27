class MergeTrainFailurePolicy
  IMPLEMENTED_RUNG_CLASSES = [
    Rungs::Restart,
    Rungs::KeepAssembly,
    Rungs::KeepFixes
  ].freeze
  IMPLEMENTED_RUNGS = IMPLEMENTED_RUNG_CLASSES.index_by(&:name).freeze

  def self.resolve(repository:, attempt_number:, retry_classification:)
    new(repository: repository, attempt_number: attempt_number, retry_classification: retry_classification).resolve
  end

  def initialize(repository:, attempt_number:, retry_classification:)
    @repository = repository
    @attempt_number = attempt_number.to_i
    @retry_classification = retry_classification.to_s.presence || "unknown"
  end

  def resolve
    return Rungs::Restart.new unless config_determined?
    # The budget applies to the instance default too. It used to be checked
    # only on the configured-ladder path, so a repository with no ladder got
    # the instance default rung on every attempt forever -- and once
    # preservation started actually relaunching trains, `keep_assembly` as the
    # instance default would have meant a train that preserves without end.
    # Past the budget there is one answer, and it is the same one a configured
    # ladder gets: restart.
    return Rungs::Restart.new if @attempt_number < 1 || @attempt_number > retry_budget_limit
    return instance_default_rung unless configured_ladder?

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
