class OperatorQuestion < ApplicationRecord
  belongs_to :job
  belongs_to :workflow
  belongs_to :run
  has_many :operator_responses, -> { order(:responded_at, :created_at) }, dependent: :destroy

  before_validation :set_defaults

  validates :text, presence: true
  validates :asked_at, presence: true
  validate :context_is_present
  validate :associations_belong_to_same_run_context

  def record_response!(text:, responded_at: Time.current)
    operator_responses.create!(text: text, responded_at: responded_at)
  end

  def question
    text
  end

  def sent_at
    asked_at
  end

  def state
    "sent"
  end

  def repository
    job.repository
  end

  private

  def set_defaults
    self.context = {} if context.nil?
    self.asked_at ||= Time.current
  end

  def context_is_present
    errors.add(:context, "can't be blank") if context.nil?
  end

  def associations_belong_to_same_run_context
    return unless run && workflow && job

    errors.add(:workflow, "must match the Run's Workflow") if run.workflow && run.workflow != workflow
    errors.add(:job, "must match the Run's Job") if run.job != job
    errors.add(:job, "must match the Workflow's Job") if workflow.job != job
  end
end
