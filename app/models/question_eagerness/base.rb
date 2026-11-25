module QuestionEagerness
  class Base
    LEVELS = %w[autonomous independent balanced collaborative inquisitive].freeze
    def self.for(name)
      const_get(name.to_s.camelize, false).new
    rescue NameError
      Balanced.new
    end

    def prompt
      "Question eagerness: #{self.class.name.demodulize.underscore}. #{guidance} Batch questions and state a default for each."
    end
  end
end
