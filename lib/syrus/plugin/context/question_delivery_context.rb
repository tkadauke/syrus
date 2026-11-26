# frozen_string_literal: true

module Syrus
  module Plugin
    module Context
      QuestionDeliveryContext = Data.define(
        :question_id, :event_type, :source, :occurred_at, :questions, :defaults,
        :answers, :answer_source, :job_id, :job_path, :active
      ) do
        def initialize(**attributes)
          super(**attributes.merge(
            questions: Array(attributes[:questions]).map { |item| item.to_h.freeze }.freeze,
            defaults: Array(attributes[:defaults]).freeze,
            answers: Array(attributes[:answers]).freeze,
            active: !!attributes[:active]
          ))
        end
      end
    end
  end
end
