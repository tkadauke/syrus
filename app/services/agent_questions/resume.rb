module AgentQuestions
  class Resume
    def self.call(question) = new(question).call

    def initialize(question)
      @question = question
      @run = question.run
    end

    def call
      resumed = transition!
      reenqueue! if resumed
      resumed
    end

    # Moves the parked Run, Step and Workflow back to work inside the
    # caller's transaction, so an answer that cannot resume rolls back with
    # it. Returns whether the Run must be re-enqueued after commit.
    def transition!
      Run.transaction do
        Lineage.lock!(@run)
        @run.reload(lock: true)
        step = @run.step.reload(lock: true)
        workflow = step.workflow.reload(lock: true)
        awaiting = @run.awaiting_answer? && step.awaiting_answer?
        blocked = @run.blocked? && step.blocked? && workflow.blocked?
        return false unless awaiting || blocked
        return false if workflow.terminal? && !blocked
        return false if workflow.job&.closed?

        if resumable_session?
          @run.prompt = answer_prompt
          @run.parent_session_id = @run.provider_session.session_id
        else
          @run.prompt = fallback_prompt
        end
        @run.finished_at = nil
        step.finished_at = nil
        workflow.finished_at = nil
        workflow.resume_from_answer! if workflow.may_resume_from_answer?
        @run.resume_from_answer!
        step.resume_from_answer!
      end
      true
    end

    def reenqueue! = @run.reenqueue!

    private

    def resumable_session?
      @run.provider_session&.session_id.present?
    end

    def fallback_prompt
      [ @run.prompt, answer_prompt ].compact.join("\n\n")
    end

    def answer_prompt
      resolution = @question.answer_source == "timeout" ? "The answer timeout applied your stated defaults." : "The operator answered your earlier questions."
      "#{resolution}\n\n#{answer_text}\n\nContinue the step using these answers."
    end

    def answer_text
      @question.questions.each_with_index.map do |item, index|
        answer = @question.answers[index]
        "Q#{index + 1}: #{item['question']}\nA#{index + 1}: #{Array(answer).join(', ')}"
      end.join("\n\n")
    end
  end
end
