class RunFailureClassification < ApplicationRecord
  belongs_to :run

  serialize :classifier_inputs, coder: JSON

  validates :classification, presence: true
  validates :classified_at, presence: true
  validates :run_id, uniqueness: true
  validates :retryable, inclusion: { in: [ true, false ] }
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
end
