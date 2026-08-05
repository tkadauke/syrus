class ProviderCircuitClearance
  MODES = %w[clear shorten].freeze

  def self.call(...) = new(...).call

  def initialize(provider:, target_user:, mode:, reason:, user:, retry_after: nil, positive_evidence: nil)
    @provider = provider.to_s
    @target_user = target_user
    @mode = mode.to_s
    @reason = reason.to_s.strip
    @user = user
    @retry_after = retry_after
    @positive_evidence = positive_evidence.to_s.strip.presence
  end

  def call
    validate!
    evidence = record_positive_evidence!
    App::ProviderAvailability.clear_cache!(user: target_user, provider: provider)
    evidence
  end

  private

  attr_reader :provider, :target_user, :mode, :reason, :user, :retry_after, :positive_evidence

  def validate!
    raise ArgumentError, "Admin access required." unless user&.admin?
    raise ArgumentError, "provider is required" if provider.blank?
    raise ArgumentError, "user is required" unless target_user
    raise ArgumentError, "mode is invalid" unless MODES.include?(mode)
    raise ArgumentError, "reason is required" if reason.blank?
    raise ArgumentError, "positive_evidence is required" if positive_evidence.blank?
    raise ArgumentError, "structured quota evidence is still open for #{provider}" if unrepaired_structured_quota_evidence?
  end

  def record_positive_evidence!
    if provider == "codex"
      return ProviderAvailabilityEvidence.record_codex_success!(
        user: target_user,
        source: "operator_circuit_repair",
        observed_at: Time.current,
        details: {
          mode: mode,
          reason: reason,
          positive_evidence: positive_evidence,
          retry_after: parsed_retry_after&.iso8601,
          repaired_by_user_id: user.id
        }
      )
    end

    ProviderAvailabilityEvidence.create!(
      user: target_user,
      provider: provider,
      status: "available",
      source: "operator_circuit_repair",
      observed_at: Time.current,
      details: ProviderAvailabilityEvidence.sanitized_details(
        mode: mode,
        reason: reason,
        positive_evidence: positive_evidence,
        retry_after: parsed_retry_after&.iso8601,
        repaired_by_user_id: user.id
      )
    )
  end

  def unrepaired_structured_quota_evidence?
    ProviderAvailabilityEvidence
      .where(user: target_user, provider: provider, status: %w[exhausted warning], source: "usage_probe")
      .unrepaired_for_circuit
      .where("observed_at >= ?", ProviderCircuitBreaker::USAGE_LIMIT_WINDOW.ago)
      .any? { |evidence| evidence.details.to_h["snapshot"].present? }
  end

  def parsed_retry_after
    return @parsed_retry_after if defined?(@parsed_retry_after)
    return @parsed_retry_after = nil if retry_after.blank?

    @parsed_retry_after = Time.zone.parse(retry_after.to_s)
  rescue ArgumentError
    raise ArgumentError, "retry_after is invalid"
  end
end
