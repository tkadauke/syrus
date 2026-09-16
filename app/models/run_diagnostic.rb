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

  configurable_retention setting_key: :run_diagnostic_retention_days, unit: :days

  scope :prunable, -> {
    cutoff = retention_cutoff
    cutoff ? where("created_at < ?", cutoff) : none
  }
end
