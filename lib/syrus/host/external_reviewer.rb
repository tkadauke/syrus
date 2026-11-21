# frozen_string_literal: true

require "syrus/plugin/external_reviewer"
require "syrus/plugin/external_review_value"

module Syrus
  module Host
    ExternalReviewer = Syrus::Plugin::ExternalReviewer
    ExternalReviewContext = Syrus::Plugin::ExternalReviewContext
    ExternalReviewResult = Syrus::Plugin::ExternalReviewResult
    ExternalReviewArtifact = Syrus::Plugin::ExternalReviewArtifact
  end
end
