module NormalizesPlannedExecutionRequirements
  extend ActiveSupport::Concern

  included do
    before_validation :normalize_planned_execution_requirements
    validate :planned_execution_requirement_must_be_valid
  end

  private

  def normalize_planned_execution_requirements
    @planned_execution_requirement_error = nil
    planned_execution_requirement_for_normalization.assign_to(self)
  rescue ArgumentError => e
    @planned_execution_requirement_error = e.message
  end

  def planned_execution_requirement_for_normalization
    PlannedExecutionRequirement.from_record(self)
  end

  def planned_execution_requirement_must_be_valid
    return if @planned_execution_requirement_error.blank?

    errors.add(:planned_execution_capabilities, @planned_execution_requirement_error)
  end
end
