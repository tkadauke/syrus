class AgentQuestionTimeoutJob < ApplicationJob
  queue_as :control_plane

  def perform(question_id)
    question = AgentQuestion.find_by(id: question_id)
    return unless question&.active? && question.times_out_at&.past?

    question.update!(timed_out_at: Time.current)
    question.answer!(answers: question.defaults, answered_by: nil, source: "timeout")
  end
end
