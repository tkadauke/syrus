module AgentQuestions
  class Resume
    def self.call(question) = new(question).call

    def initialize(question)
      @question = question
      @run = question.run
    end

    def call
      Run.transaction do
        Lineage.lock!(@run)
        @run.reload
        step = @run.step.reload
        return false unless @run.awaiting_answer? && step.awaiting_answer?

        @run.prompt = fallback_prompt unless resumable_session?
        @run.parent_session_id = @run.provider_session.session_id if resumable_session?
        @run.resume_from_answer!
        @run.save!
        step.resume_from_answer!
        step.save!
      end
      @run.reenqueue!
      true
    end

    private

    def resumable_session?
      @run.provider_session&.session_id.present?
    end

    def fallback_prompt
      [ @run.prompt, "The operator answered your earlier questions:\n\n#{answer_text}\n\nContinue the step using these answers." ].compact.join("\n\n")
    end

    def answer_text
      @question.questions.each_with_index.map do |item, index|
        answer = @question.answers[index]
        "Q#{index + 1}: #{item['question']}\nA#{index + 1}: #{Array(answer).join(', ')}"
      end.join("\n\n")
    end
  end
end
