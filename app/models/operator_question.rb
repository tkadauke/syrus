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

  def channel=(value)
    @legacy_channel = value.to_s
    merge_legacy_channel
  end

  def context=(value)
    normalized = value.is_a?(Hash) || value.nil? ? value : { "context" => value }
    super(normalized)
    merge_legacy_channel
  end

  def question
    text
  end

  def question=(value)
    self.text = value
  end

  def sent_at
    asked_at
  end

  def sent_at=(value)
    self.asked_at = value
  end

  def repository=(_value)
    # Legacy writer kept for tests and older dispatch seams. Repository
    # is derived from the owning Job.
  end

  def channel
    context.is_a?(Hash) ? context["channel"] : nil
  end

  def state
    "sent"
  end

  def repository
    job.repository
  end

  private

  def set_defaults
    self.workflow ||= run&.workflow
    self.job ||= run&.job
    self.context = {} if context.nil?
    self.asked_at ||= Time.current
  end

  def merge_legacy_channel
    return if @legacy_channel.blank?

    current = self[:context]
    current = {} unless current.is_a?(Hash)
    self[:context] = current.merge("channel" => @legacy_channel)
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
