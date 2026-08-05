class ProviderAvailabilityEvidence < ApplicationRecord
  CIRCUIT_REPAIR_STATUSES = %w[false_positive inconclusive transient].freeze

  STATUSES = %w[
    available
    exhausted
    warning
    probe_inconclusive
    probe_unavailable
    auth_error
    unsupported
  ].freeze

  POSITIVE_STATUSES = %w[available].freeze
  NEGATIVE_STATUSES = %w[exhausted warning].freeze
  PROBE_SOURCES = %w[usage_probe].freeze

  belongs_to :user
  belongs_to :run, optional: true
  belongs_to :chat_session, optional: true
  belongs_to :chat_message, optional: true
  belongs_to :repaired_by_user, class_name: "User", optional: true

  validates :provider, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :source, presence: true
  validates :observed_at, presence: true
  validates :repair_status, inclusion: { in: CIRCUIT_REPAIR_STATUSES }, allow_nil: true

  normalizes :provider, :account_id, :model, :status, :source, with: ->(value) { value.to_s.strip.presence }

  scope :recent, -> { order(observed_at: :desc, id: :desc) }
  scope :positive, -> { where(status: POSITIVE_STATUSES) }
  scope :negative, -> { where(status: NEGATIVE_STATUSES) }
  scope :unrepaired_for_circuit, -> { where(repair_status: nil) }
  scope :for_scope, ->(user:, provider:, account_id: nil, model: nil) {
    scope = where(user: user, provider: provider.to_s)
    scope = account_id.present? ? scope.where(account_id: [ account_id.to_s, nil ]) : scope
    scope.where(model: matching_models_for(model))
  }

  def self.record_codex_success!(user:, source:, model: nil, run: nil, chat_session: nil, chat_message: nil, observed_at: Time.current, details: {})
    account_id = CodexAccountScope.for_user(user)
    evidence = create!(
      user: user,
      run: run,
      chat_session: chat_session,
      chat_message: chat_message,
      provider: "codex",
      account_id: account_id,
      model: model.presence || CodexInvocation.configured_model,
      status: "available",
      source: source,
      observed_at: observed_at,
      details: sanitized_details(details)
    )
    clear_codex_usage_cache_after_success!(user, evidence)
    App::ProviderAvailability.clear_cache!(user: user, provider: "codex")
    evidence
  end

  def self.record_codex_probe!(user:, status:, snapshot:, message:, http_status: nil, observed_at: Time.current)
    account_id = CodexAccountScope.for_user(user)
    create!(
      user: user,
      provider: "codex",
      account_id: account_id,
      model: nil,
      status: evidence_status_for_probe(status),
      source: "usage_probe",
      observed_at: observed_at,
      http_status: http_status,
      details: sanitized_details(
        message: message,
        snapshot: snapshot
      )
    )
  end

  def self.record_codex_invocation_failure!(run:, status: "exhausted", model: nil, message: nil, observed_at: Time.current)
    return unless run&.user

    create!(
      user: run.user,
      run: run,
      provider: "codex",
      account_id: CodexAccountScope.for_user(run.user),
      model: model.presence || ProviderUsageLimit.extract_model(message),
      status: status,
      source: "codex_invocation_failure",
      observed_at: observed_at,
      details: sanitized_details(
        run_id: run.id,
        agent_outcome: run.agent_outcome,
        failure_classification: run.run_failure_classification&.classification,
        message: message
      )
    )
  end

  def self.latest_for_scope(user:, provider:, account_id: nil, model: nil)
    for_scope(user: user, provider: provider, account_id: account_id, model: model).recent.first
  end

  def self.latest_positive_after?(user:, provider:, observed_at:, account_id: nil, model: nil)
    matching_positive_scope(user: user, provider: provider, account_id: account_id, model: model)
      .where("observed_at > ?", observed_at)
      .exists?
  end

  def self.suppressed_by_positive_after?(user:, provider:, observed_at:, account_id: nil, model: nil)
    if provider.to_s == "codex" && ProviderUsageLimit.suspicious_model?(model)
      return matching_positive_scope(user: user, provider: provider, account_id: account_id, model: nil, any_model: true)
        .where("observed_at > ?", observed_at)
        .exists?
    end

    latest_positive_after?(
      user: user,
      provider: provider,
      account_id: account_id,
      model: model,
      observed_at: observed_at
    )
  end

  def self.matching_positive_after(user:, provider:, observed_at:, account_id: nil, model: nil)
    matching_positive_scope(user: user, provider: provider, account_id: account_id, model: model)
      .where("observed_at > ?", observed_at)
      .recent
      .first
  end

  def self.latest_positive_negative_for_provider(provider)
    where(provider: provider.to_s)
      .where(status: POSITIVE_STATUSES + NEGATIVE_STATUSES + %w[probe_inconclusive probe_unavailable])
      .recent
      .limit(100)
      .group_by(&:status)
      .values
      .flat_map(&:first)
      .compact
      .sort_by(&:observed_at)
      .reverse
      .map(&:summary)
  end

  def summary
    {
      status: status,
      source: source,
      observed_at: observed_at&.iso8601,
      provider: provider,
      account_id: account_id,
      model: model,
      run_id: run_id,
      chat_session_id: chat_session_id,
      chat_message_id: chat_message_id,
      http_status: http_status,
      details: details,
      repair: repair_summary
    }.compact
  end

  def positive? = POSITIVE_STATUSES.include?(status)
  def negative? = NEGATIVE_STATUSES.include?(status)
  def repaired_for_circuit? = repair_status.present?

  def mark_circuit_repair!(status:, reason:, user:)
    update!(
      repair_status: status.to_s,
      repair_reason: reason.to_s,
      repaired_at: Time.current,
      repaired_by_user: user
    )
    App::ProviderAvailability.clear_cache!(user: self.user, provider: provider)
  end

  def repair_summary
    return unless repaired_for_circuit?

    {
      status: repair_status,
      reason: repair_reason,
      repaired_at: repaired_at&.iso8601,
      repaired_by_user_id: repaired_by_user_id
    }.compact
  end

  def self.evidence_status_for_probe(status)
    case status.to_s
    when "ok" then "available"
    when "warning" then "warning"
    when "exhausted" then "exhausted"
    when "auth_error" then "auth_error"
    when "unsupported" then "unsupported"
    when "probe_inconclusive" then "probe_inconclusive"
    else "probe_unavailable"
    end
  end

  def self.matching_models_for(model)
    normalized = model.to_s.strip.presence
    normalized.present? ? [ normalized, nil ] : [ nil ]
  end

  def self.matching_positive_scope(user:, provider:, account_id: nil, model: nil, any_model: false)
    scope = where(user: user, provider: provider.to_s).positive
    scope = account_id.present? ? scope.where(account_id: [ account_id.to_s, nil ]) : scope
    return scope if any_model

    normalized_model = model.to_s.strip.presence
    normalized_model.present? ? scope.where(model: [ normalized_model, nil ]) : scope
  end

  def self.sanitized_details(value)
    JSON.parse(JSON.generate(value || {})).then { |json| sanitize(json) }
  end

  def self.sanitize(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, raw), memo|
        key = key.to_s
        next if key.match?(/token|secret|authorization|api[_-]?key|auth_json/i)

        memo[key] = sanitize(raw)
      end
    when Array
      value.first(20).map { |entry| sanitize(entry) }
    when String
      value.truncate(1_000)
    else
      value
    end
  end

  def self.clear_codex_usage_cache_after_success!(user, evidence)
    return unless user.codex_usage_status == "exhausted"

    user.update!(
      codex_usage_status: "ok",
      codex_usage_observed_at: evidence.observed_at,
      codex_usage_snapshot: {
        "source" => evidence.source,
        "status" => "available",
        "observed_at" => evidence.observed_at.iso8601,
        "model" => evidence.model,
        "account_id" => evidence.account_id
      }.compact
    )
  end
end
