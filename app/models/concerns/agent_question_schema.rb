module AgentQuestionSchema
  extend ActiveSupport::Concern

  class_methods do
    def normalize_questions(questions)
      return unless questions.is_a?(Array) && questions.length.between?(1, 4)

      questions.map do |raw|
        return unless raw.is_a?(Hash)
        question = raw.stringify_keys
        text = question["question"].to_s.gsub('\\n', "\n").strip
        return if text.blank?
        options = question["options"]
        if options
          return unless options.is_a?(Array)
          options = options.map { |option| option.to_s.strip }
          return if options.empty? || options.any?(&:blank?)
        end
        multiple = question["multiple"] == true
        return if multiple && options.blank?

        { "question" => text, "options" => options, "multiple" => multiple }
      end
    end
  end

  private

  def normalize_answers(answers)
    return unless questions.is_a?(Array) && answers.is_a?(Array) && answers.length == questions.length

    questions.each_with_index.map do |question, index|
      if question["multiple"]
        return unless answers[index].is_a?(Array)
        values = answers[index].map { |value| value.to_s.strip }.reject(&:blank?)
        return if values.empty?
        values
      else
        value = answers[index].to_s.strip
        return if value.blank?
        value
      end
    end
  end
end
