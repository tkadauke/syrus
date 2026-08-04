class GithubAuthFallbackDiagnostic < ApplicationRecord
  belongs_to :repository
  belongs_to :installation, optional: true
  belongs_to :run, optional: true

  validates :operation_type, presence: true
  validates :error_class, presence: true

  scope :recent, -> { order(created_at: :desc) }
end
