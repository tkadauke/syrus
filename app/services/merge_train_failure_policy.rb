class MergeTrainFailurePolicy
  IMPLEMENTED_RUNG_CLASSES = [
    Rungs::Restart,
    Rungs::KeepAssembly
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
    return Rungs::Restart.new if @attempt_number < 1 || @attempt_number > retry_budget_limit

    rung_names = ladder.drop(@attempt_number - 1).first(retry_budget_limit - @attempt_number + 1)
    rung_names.each do |name|
      rung_class = IMPLEMENTED_RUNGS[name.to_s]
      return rung_class.new if rung_class
    end

    Rungs::Restart.new
  end

  private

  def ladder
    @ladder ||= @repository&.merge_train_failure_policy_ladder || [ AppSetting.merge_train_failure_policy ]
  end

  def retry_budget_limit
    AutoRetryAttempt.retry_budget_limit_for(@retry_classification)
  end
end
