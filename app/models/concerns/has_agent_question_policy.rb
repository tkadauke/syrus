module HasAgentQuestionPolicy
  extend ActiveSupport::Concern

  included do
    validates :question_eagerness, inclusion: { in: QuestionEagerness::Base::LEVELS }, allow_nil: true
    validates :question_answer_timeout_seconds,
      numericality: { only_integer: true, greater_than_or_equal_to: 1.hour.to_i, less_than_or_equal_to: 4.weeks.to_i },
      allow_nil: true
  end
end
