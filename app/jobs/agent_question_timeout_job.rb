class AgentQuestionTimeoutJob < ApplicationJob
  queue_as :control_plane

  def perform(question_id)
    question = AgentQuestion.find_by(id: question_id)
    question&.timeout!
  end
end
