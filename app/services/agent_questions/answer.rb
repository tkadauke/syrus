module AgentQuestions
  class Answer
    def self.call(question:, answers:, answered_by:, source:)
      question.answer!(answers:, answered_by:, source:)
    end
  end
end
