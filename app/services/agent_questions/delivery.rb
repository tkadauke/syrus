module AgentQuestions
  module Delivery
    module_function

    def publish(event)
      question = event.agent_question
      run = question.run
      job = run&.job
      context = Syrus::Plugin::Context::QuestionDeliveryContext.new(
        question_id: question.id,
        event_type: event.event_type,
        source: event.source,
        occurred_at: event.occurred_at,
        questions: question.questions_payload,
        defaults: question.defaults,
        answers: question.answers,
        answer_source: question.answer_source,
        job_id: job&.id,
        job_path: job && "/jobs/#{job.id}",
        active: question.active?
      )
      Syrus::Plugin::Dispatch.call(:question_delivery, :question_events, context)
    end

    def answer(question_id:, job_id:, answers:, answered_by:, source:)
      return false unless answered_by

      question = AgentQuestion.active.where.not(run_id: nil)
        .joins(run: :job)
        .merge(Job.visible_to(answered_by))
        .find_by(id: question_id, runs: { job_id: job_id })
      return false unless question
      return false unless JobPolicy.new(answered_by, question.run.job).write?

      AgentQuestions::Answer.call(question:, answers:, answered_by:, source:)
    end
  end
end
