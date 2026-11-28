class Coworkers::JobAutonomyShadowDecision < Syrus::Host::Record
  self.table_name = "coworker_job_autonomy_shadow_decisions"

  belongs_to :coworker, class_name: "Coworkers::Coworker"
  belongs_to :permission_rule, class_name: "PermissionRule"
  belongs_to :repository, class_name: "Repository"
  belongs_to :job, class_name: "Job", optional: true
  belongs_to :chat_pending_action, class_name: "ChatPendingAction"

  validates :action, inclusion: { in: Coworkers::JobAutonomy::CAPABILITIES.keys }
  validates :predicted_decision, inclusion: { in: %w[act abstain] }
  validates :operator_decision, inclusion: { in: %w[act abstain] }, allow_nil: true

  after_initialize do
    self.evidence ||= {}
    self.guardrail_outcomes ||= {}
  end

  def agreement? = operator_decision.present? && predicted_decision == operator_decision
end
