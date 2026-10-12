class ProviderRoutingRule < ApplicationRecord
  SCOPE_TYPES = %w[ user repository job ].freeze
  DEFAULT_TASK_KEY = "default".freeze
  TRIGGER_TYPES = %w[ default step chat_role legacy_task ].freeze
  ACTION_STRATEGIES = %w[ fallback_order weighted ].freeze
  CONDITION_KEYS = %w[ workflow_trigger_kind usage budget day_time repository job_metadata ].freeze

  belongs_to :user
  belongs_to :repository, optional: true
  belongs_to :job, optional: true

  validates :scope_type, presence: true, inclusion: { in: SCOPE_TYPES }
  validates :scope_id, presence: true
  validates :task_key, presence: true
  validates :position, presence: true, numericality: { only_integer: true, greater_than: 0 },
                       uniqueness: { scope: [ :scope_type, :scope_id ] }
  validate :scope_owner_is_consistent
  validate :trigger_is_valid
  validate :conditions_are_valid
  validate :action_is_valid
  validate :candidates_are_valid

  before_validation :normalize_scope_columns
  before_validation :normalize_position
  before_validation :normalize_payloads

  def scope_type_user? = scope_type == "user"
  def scope_type_repository? = scope_type == "repository"
  def scope_type_job? = scope_type == "job"

  def action_candidates
    Array(action.to_h["candidates"].presence || candidates)
  end

  def matches?(invocation:, job: nil, workflow_trigger_kind: nil, now: Time.current)
    match_details(invocation: invocation, job: job, workflow_trigger_kind: workflow_trigger_kind, now: now)["matched"]
  end

  def match_details(invocation:, job: nil, workflow_trigger_kind: nil, now: Time.current)
    invocation = invocation.stringify_keys
    condition_results = {
      "workflow_trigger_kind" => workflow_trigger_condition_result(workflow_trigger_kind),
      "day_time" => day_time_condition_result(now),
      "repository" => repository_condition_result(job&.repository),
      "job_metadata" => job_metadata_condition_result(job),
      "usage" => passive_condition_result("usage"),
      "budget" => passive_condition_result("budget")
    }
    trigger_result = {
      "matched" => trigger_matches?(invocation),
      "expected" => trigger,
      "actual" => invocation
    }

    {
      "matched" => trigger_result["matched"] && condition_results.values.all? { |result| result["matched"] },
      "trigger" => trigger_result,
      "conditions" => condition_results
    }
  end

  private

  def normalize_scope_columns
    self.repository_id ||= scope_id if scope_type_repository?
    self.job_id ||= scope_id if scope_type_job?

    self.user_id ||= scope_id if scope_type_user?
    self.user_id ||= repository&.user_id if scope_type_repository?
    self.user_id ||= job&.effective_owner_id if scope_type_job?
    self.repository_id ||= job&.repository_id if scope_type_job?
  end

  def normalize_position
    return if position.present? || scope_type.blank? || scope_id.blank?

    self.position = self.class.where(scope_type: scope_type, scope_id: scope_id).maximum(:position).to_i + 1
  end

  def normalize_payloads
    self.candidates ||= []
    self.task_key = task_key.to_s.strip.presence || DEFAULT_TASK_KEY
    self.trigger = normalize_hash(trigger.presence || legacy_trigger)
    self.conditions = normalize_hash(conditions.presence || {})
    self.action = normalize_hash(action.presence || legacy_action)
  end

  def legacy_trigger
    task_key == DEFAULT_TASK_KEY ? { type: "default" } : { type: "legacy_task", task_key: task_key }
  end

  def legacy_action
    { strategy: "fallback_order", candidates: candidates }
  end

  def normalize_hash(value)
    value.respond_to?(:to_h) ? value.to_h.deep_stringify_keys : value
  end

  def scope_owner_is_consistent
    errors.add(:repository, "must be present for repository-scoped rules") if scope_type_repository? && repository_id.blank?
    errors.add(:job, "must be present for job-scoped rules") if scope_type_job? && job_id.blank?

    return if user_id.blank?

    errors.add(:user_id, "must match the user scope") if scope_type_user? && user_id != scope_id
    errors.add(:scope_id, "must match repository_id") if scope_type_repository? && repository_id.present? && repository_id != scope_id
    errors.add(:user_id, "must own the repository rule") if scope_type_repository? && repository && repository.user_id != user_id
    errors.add(:scope_id, "must match job_id") if scope_type_job? && job_id.present? && job_id != scope_id
    errors.add(:user_id, "must own the job rule") if scope_type_job? && job && job.effective_owner_id != user_id
    errors.add(:repository_id, "must match the job repository") if scope_type_job? && job && repository_id.present? && repository_id != job.repository_id
  end

  def trigger_is_valid
    unless trigger.is_a?(Hash)
      errors.add(:trigger, "must be an object")
      return
    end

    type = trigger["type"].to_s
    errors.add(:trigger, "has unknown type #{type.inspect}") unless TRIGGER_TYPES.include?(type)

    validate_step_trigger if type == "step"
    validate_chat_role_trigger if type == "chat_role"
    validate_legacy_task_trigger if type == "legacy_task"
  end

  def validate_step_trigger
    kind = trigger["kind"].to_s
    errors.add(:trigger, "step kind is required") if kind.blank?
    errors.add(:trigger, "step kind must be agentic") if kind.present? && !Step::Kind.agentic_values.include?(kind)
  end

  def validate_chat_role_trigger
    role = trigger["role"].to_s
    errors.add(:trigger, "chat role is required") if role.blank?
    errors.add(:trigger, "chat role is unknown") if role.present? && !AgentRole::CHAT_ROLES.include?(role)
  end

  def validate_legacy_task_trigger
    errors.add(:trigger, "legacy task_key is required") if trigger["task_key"].to_s.blank?
  end

  def conditions_are_valid
    unless conditions.is_a?(Hash)
      errors.add(:conditions, "must be an object")
      return
    end

    unknown_keys = conditions.keys - CONDITION_KEYS
    errors.add(:conditions, "contains unknown keys: #{unknown_keys.join(", ")}") if unknown_keys.any?
    validate_workflow_trigger_condition
    validate_predicate_hash(:usage)
    validate_predicate_hash(:budget)
    validate_day_time_condition
    validate_repository_condition
    validate_job_metadata_condition
  end

  def validate_workflow_trigger_condition
    value = conditions["workflow_trigger_kind"]
    return if value.blank?

    invalid = Array(value) - Workflow::TriggerKind.values
    errors.add(:conditions, "workflow_trigger_kind contains unknown values: #{invalid.join(", ")}") if invalid.any?
  end

  def validate_predicate_hash(key)
    value = conditions[key.to_s]
    return if value.blank?

    errors.add(:conditions, "#{key} must be an object") unless value.is_a?(Hash)
  end

  def validate_day_time_condition
    value = conditions["day_time"]
    return if value.blank? || !value.is_a?(Hash)

    days = value["days"]
    invalid_days = Array(days) - %w[ monday tuesday wednesday thursday friday saturday sunday ]
    errors.add(:conditions, "day_time days contain unknown values: #{invalid_days.join(", ")}") if invalid_days.any?

    value.slice("start", "end").each do |key, time|
      errors.add(:conditions, "day_time #{key} must be HH:MM") unless time.to_s.match?(/\A\d{2}:\d{2}\z/)
    end
  end

  def validate_repository_condition
    value = conditions["repository"]
    return if value.blank?

    unless value.is_a?(Hash)
      errors.add(:conditions, "repository must be an object")
      return
    end

    errors.add(:conditions, "repository ids must be an array") if value.key?("ids") && !value["ids"].is_a?(Array)
    errors.add(:conditions, "repository names must be an array") if value.key?("names") && !value["names"].is_a?(Array)
    errors.add(:conditions, "repository owners must be an array") if value.key?("owners") && !value["owners"].is_a?(Array)
  end

  def validate_job_metadata_condition
    value = conditions["job_metadata"]
    return if value.blank?

    unless value.is_a?(Hash)
      errors.add(:conditions, "job_metadata must be an object")
      return
    end

    errors.add(:conditions, "job_metadata kinds must be an array") if value.key?("kinds") && !value["kinds"].is_a?(Array)
    errors.add(:conditions, "job_metadata priorities must be an array") if value.key?("priorities") && !value["priorities"].is_a?(Array)
  end

  def action_is_valid
    unless action.is_a?(Hash)
      errors.add(:action, "must be an object")
      return
    end

    strategy = action["strategy"].to_s
    errors.add(:action, "has unknown strategy #{strategy.inspect}") unless ACTION_STRATEGIES.include?(strategy)
    errors.add(:action, "candidates must be an array") unless action["candidates"].is_a?(Array)
  end

  def candidates_are_valid
    candidate_list = action_candidates

    unless candidates.is_a?(Array) && candidate_list.is_a?(Array)
      errors.add(:candidates, "must be an array of candidate objects")
      return
    end

    valid_providers = Syrus::PluginRegistry.providers_for(:agent_provider).map(&:provider_key)

    candidate_list.each_with_index do |candidate, index|
      validate_candidate(candidate, index, valid_providers)
    end
  end

  def validate_candidate(candidate, index, valid_providers)
    unless candidate.is_a?(Hash)
      errors.add(:candidates, "entry #{index} must be an object with a provider key")
      return
    end

    candidate = candidate.stringify_keys
    provider = candidate["provider"].presence

    if provider.blank?
      errors.add(:candidates, "entry #{index} is missing a provider")
      return
    end

    unless valid_providers.include?(provider)
      errors.add(:candidates, "entry #{index} has unknown provider #{provider.inspect}")
      return
    end

    errors.add(:candidates, "entry #{index} weight must be positive") if candidate.key?("weight") && candidate["weight"].to_f <= 0
    validate_candidate_model(provider, candidate["model"], index) if candidate["model"].present?
  end

  # Soft check: only enforced once a provider actually exposes a model
  # catalog (the model-effort-plumbing Epic). No provider implements
  # `.available_models` yet, so this is a no-op today by design.
  def validate_candidate_model(provider, model, index)
    provider_class = AgentProviders.for(provider)
    return unless provider_class.respond_to?(:available_models)

    catalog = Array(provider_class.available_models).map { |entry| entry.respond_to?(:id) ? entry.id : entry.to_s }
    return if catalog.blank?
    return if catalog.include?(model)

    errors.add(:candidates, "entry #{index} has model #{model.inspect} not in #{provider}'s known models")
  rescue AgentProviders::ConfigurationError
    nil
  end

  def trigger_matches?(invocation)
    type = trigger["type"].to_s
    return invocation["type"] == "default" if type == "default"
    return invocation["type"] == "step" && invocation["kind"] == trigger["kind"] if type == "step"
    return invocation["type"] == "chat_role" && invocation["role"] == trigger["role"] if type == "chat_role"

    invocation["task_key"] == trigger["task_key"] || invocation["kind"] == trigger["task_key"]
  end

  def workflow_trigger_condition_matches?(workflow_trigger_kind)
    expected = conditions["workflow_trigger_kind"]
    expected.blank? || (workflow_trigger_kind.present? && Array(expected).include?(workflow_trigger_kind.to_s))
  end

  def day_time_condition_matches?(now)
    value = conditions["day_time"]
    return true if value.blank?

    day = now.strftime("%A").downcase
    return false if value["days"].present? && !Array(value["days"]).include?(day)

    current = now.strftime("%H:%M")
    return false if value["start"].present? && current < value["start"].to_s
    return false if value["end"].present? && current > value["end"].to_s

    true
  end

  def repository_condition_matches?(target_repository)
    value = conditions["repository"]
    return true if value.blank?
    return false if target_repository.blank?

    return false if value["ids"].present? && !Array(value["ids"]).map(&:to_i).include?(target_repository.id)
    return false if value["owners"].present? && !Array(value["owners"]).map(&:to_s).include?(target_repository.owner)
    return false if value["names"].present? && !Array(value["names"]).map(&:to_s).include?(target_repository.name)

    true
  end

  def job_metadata_condition_matches?(target_job)
    value = conditions["job_metadata"]
    return true if value.blank?
    return false if target_job.blank?

    return false if value["kinds"].present? && !Array(value["kinds"]).map(&:to_s).include?(target_job.kind)
    return false if value["priorities"].present? && !Array(value["priorities"]).map(&:to_s).include?(target_job.priority)
    return false if value.key?("investigation") && ActiveModel::Type::Boolean.new.cast(value["investigation"]) != target_job.investigation?

    true
  end

  def workflow_trigger_condition_result(workflow_trigger_kind)
    expected = conditions["workflow_trigger_kind"]
    {
      "configured" => expected.present?,
      "matched" => workflow_trigger_condition_matches?(workflow_trigger_kind),
      "expected" => expected,
      "actual" => workflow_trigger_kind
    }.compact
  end

  def day_time_condition_result(now)
    {
      "configured" => conditions["day_time"].present?,
      "matched" => day_time_condition_matches?(now),
      "expected" => conditions["day_time"],
      "actual" => now.iso8601
    }.compact
  end

  def repository_condition_result(target_repository)
    actual = if target_repository
      { "id" => target_repository.id, "owner" => target_repository.owner, "name" => target_repository.name }
    end

    {
      "configured" => conditions["repository"].present?,
      "matched" => repository_condition_matches?(target_repository),
      "expected" => conditions["repository"],
      "actual" => actual
    }.compact
  end

  def job_metadata_condition_result(target_job)
    actual = if target_job
      { "kind" => target_job.kind, "priority" => target_job.priority, "investigation" => target_job.investigation? }
    end

    {
      "configured" => conditions["job_metadata"].present?,
      "matched" => job_metadata_condition_matches?(target_job),
      "expected" => conditions["job_metadata"],
      "actual" => actual
    }.compact
  end

  def passive_condition_result(key)
    value = conditions[key]
    {
      "configured" => value.present?,
      "matched" => true,
      "expected" => value,
      "reason" => value.present? ? "condition_not_evaluated_by_provider_routing" : nil
    }.compact
  end
end
