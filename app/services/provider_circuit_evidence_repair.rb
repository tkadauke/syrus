class ProviderCircuitEvidenceRepair
  REPAIR_STATUSES = %w[false_positive inconclusive transient].freeze
  EVIDENCE_TYPES = %w[provider_availability_evidence run_failure_classification].freeze

  def self.call(...) = new(...).call

  def initialize(evidence_type:, evidence_id:, repair_status:, reason:, user:)
    @evidence_type = evidence_type.to_s
    @evidence_id = evidence_id
    @repair_status = repair_status.to_s
    @reason = reason.to_s.strip
    @user = user
  end

  def call
    validate!
    record.mark_circuit_repair!(status: repair_status, reason: reason, user: user)
    clear_availability_cache!
    record
  end

  private

  attr_reader :evidence_type, :evidence_id, :repair_status, :reason, :user

  def validate!
    raise ArgumentError, "Admin access required." unless user&.admin?
    raise ArgumentError, "evidence_type is invalid" unless EVIDENCE_TYPES.include?(evidence_type)
    raise ArgumentError, "repair_status is invalid" unless REPAIR_STATUSES.include?(repair_status)
    raise ArgumentError, "reason is required" if reason.blank?
    raise ArgumentError, "structured quota evidence cannot be repaired through provider-circuit evidence override" if structured_quota_evidence?
  end

  def record
    @record ||= case evidence_type
    when "provider_availability_evidence"
      ProviderAvailabilityEvidence.find(evidence_id)
    when "run_failure_classification"
      RunFailureClassification.includes(run: :user).find(evidence_id)
    end
  end

  def structured_quota_evidence?
    return false unless record.is_a?(ProviderAvailabilityEvidence)
    return false unless record.source == "usage_probe"
    return false unless record.status.in?(%w[exhausted warning])

    record.details.to_h["snapshot"].present?
  end

  def clear_availability_cache!
    provider = record.respond_to?(:provider) ? record.provider : record.run&.agent_provider
    evidence_user = record.respond_to?(:user) ? record.user : record.run&.user
    App::ProviderAvailability.clear_cache!(user: evidence_user, provider: provider) if evidence_user && provider.present?
  end
end
