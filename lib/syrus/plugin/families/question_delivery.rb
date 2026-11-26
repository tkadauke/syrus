# frozen_string_literal: true

module Syrus
  module Plugin
    module Families; end

    definition = Family.define(:question_delivery, built_in: true) do
      shape :facet
      capability :question_events, composition: :broadcast, absent: nil, decline: nil,
        tier: :provisional, context: Context::QuestionDeliveryContext
    end
    Families.const_set(:QuestionDelivery, definition)
  end
end
