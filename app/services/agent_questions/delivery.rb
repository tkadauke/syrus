module AgentQuestions
  class Delivery
    class << self
      def deliver(event)
        question = event.agent_question
        notify_owner!(question) if event.event_type == "asked" && question.run_id
        Syrus::Plugin::Dispatch.call(:question_delivery, :question_events, context_for(event))
      end

      def answer(question_id:, job_id:, answers:, answered_by:, source:)
        question = AgentQuestion.active.where(id: question_id)
                                .joins(run: :job).find_by(runs: { job_id: job_id })
        return false unless question
        return false unless JobPolicy.new(answered_by, question.run.job).write?

        AgentQuestions::Answer.call(question:, answers:, answered_by:, source:)
      end

      private

      def notify_owner!(question)
        job = question.run.job
        owner = job.owner_user
        return unless owner

        NotificationService.create_for(
          user: owner,
          kind: "agent_question_asked",
          job: job,
          repository: job.repository,
          body: I18n.t("notifications.agent_question_asked", job: job.slug),
          target_path: "/jobs/#{job.id}#agent-question-#{question.id}",
          dedupe_key: "agent-question:#{question.id}:asked"
        )
      end

      def context_for(event)
        question = event.agent_question
        job = question.run&.job
        Syrus::Plugin::Context::QuestionDeliveryContext.new(
          question_id: question.id,
          event_type: event.event_type,
          source: event.source,
          occurred_at: event.occurred_at,
          questions: question.questions_payload,
          defaults: question.defaults,
          answers: question.answers,
          answer_source: question.answer_source,
          job_id: job&.id,
          job_path: job ? "/jobs/#{job.id}#agent-question-#{question.id}" : nil,
          active: question.active?
        )
      end
    end
  end
end
