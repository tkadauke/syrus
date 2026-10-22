class WorkflowArtifactValue < ApplicationRecord
  belongs_to :workflow, inverse_of: :workflow_artifact_values

  validates :key, presence: true, uniqueness: { scope: :workflow_id }

  serialize :value, coder: JSON
end
