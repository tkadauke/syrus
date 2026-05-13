module OperatorChat
  module Channels
    class InSyrus
      def self.deliver!(operator_question)
        session = ChatSession.create!(
          repository: operator_question.repository,
          user: operator_question.job.user,
          title: "Question about ##{operator_question.job.issue_number || operator_question.job.id}",
          last_message_at: Time.current
        )
        session.messages.create!(
          role: "system",
          content: {
            "kind" => "operator_question",
            "operator_question_id" => operator_question.id,
            "question" => operator_question.question,
            "context" => message_context(operator_question)
          }
        )
      end

      def self.message_context(operator_question)
        context = operator_question.context
        context.is_a?(Hash) ? context.fetch("context", context) : context
      end
    end
  end
end
