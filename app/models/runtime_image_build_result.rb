# Terminal outcome of a RuntimeImageBuildRequest. Written exactly once, in the
# same transaction that moves the request to a terminal state.
class RuntimeImageBuildResult < ApplicationRecord
  OUTCOMES = %w[succeeded failed canceled rejected].freeze

  belongs_to :request, class_name: "RuntimeImageBuildRequest", foreign_key: :runtime_image_build_request_id,
             inverse_of: :result
  belongs_to :runtime_image, optional: true

  attribute :details, :json, default: -> { {} }
  before_validation { self.details ||= {} }

  validates :outcome, inclusion: { in: OUTCOMES }
  validates :finished_at, presence: true
  validates :runtime_image_build_request_id, uniqueness: true
  validates :runtime_image, presence: true, if: -> { outcome == "succeeded" }

  def succeeded? = outcome == "succeeded"
end
