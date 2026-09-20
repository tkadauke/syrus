class RunDiagnostic < ApplicationRecord
  include HasConfigurableRetention

  belongs_to :run

  # JSON-on-text columns. Letting Rails serialize keeps the model
  # surface clean (Hash in/out) while leaving the underlying TEXT
  # column easy to inspect via SQL when needed.
  serialize :git_snapshot,         coder: JSON
  serialize :environment_snapshot, coder: JSON
  serialize :repo_snapshot,        coder: JSON

  validates :error_class, presence: true

  after_commit :refresh_failure_classification!, on: [ :create, :update ]

  configurable_retention setting_key: :run_diagnostic_retention_days, unit: :days

  scope :prunable, -> {
    cutoff = retention_cutoff
    cutoff ? where("created_at < ?", cutoff) : none
  }

  private

  def refresh_failure_classification!
    return unless run&.failed?

    RunFailureClassifier.persist!(run.reload)
  rescue StandardError => e
    Rails.logger.warn("[RunDiagnostic##{id}] failed to refresh Run ##{run_id} classification: #{e.class}: #{e.message}")
  end
end
