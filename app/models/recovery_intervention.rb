class RecoveryIntervention < ApplicationRecord
  belongs_to :job
  belongs_to :source_workflow, class_name: "Workflow", optional: true
  belongs_to :source_step, class_name: "Step", optional: true
  belongs_to :source_run, class_name: "Run", optional: true
  belongs_to :resulting_workflow, class_name: "Workflow", optional: true
  belongs_to :resulting_step, class_name: "Step", optional: true
  belongs_to :resulting_run, class_name: "Run", optional: true

  attribute :failure_evidence, :json, default: -> { {} }

  validates :actor_type, :origin, :action, :recovery_kind, :recovery_mode, :performed_at, presence: true
  validate :failure_evidence_is_object

  private

  def failure_evidence_is_object
    errors.add(:failure_evidence, I18n.t("server.errors.recovery_intervention.failure_evidence_must_be_object")) unless failure_evidence.is_a?(Hash)
  end
end
