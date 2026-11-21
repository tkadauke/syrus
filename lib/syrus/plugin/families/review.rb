# frozen_string_literal: true

module Syrus
  module Plugin
    definition = Family.define(:review, built_in: true) do
      shape :facet
      capability :external_reviewer,
        composition: :first_claim,
        absent: nil,
        tier: :provisional,
        context: ExternalReviewContext,
        returns: ExternalReviewer
    end

    module Families; end
    Families.const_set(:Review, definition)
  end
end
