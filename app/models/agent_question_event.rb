class AgentQuestionEvent < ApplicationRecord
  belongs_to :agent_question

  after_create_commit { AgentQuestions::Delivery.publish(self) }

  validates :event_type, inclusion: { in: %w[asked answered withdrawn timed_out] }
  validates :source, :occurred_at, presence: true
end
