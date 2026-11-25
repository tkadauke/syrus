class AgentQuestionEvent < ApplicationRecord
  belongs_to :agent_question

  validates :event_type, inclusion: { in: %w[asked answered withdrawn timed_out] }
  validates :source, :occurred_at, presence: true
end
