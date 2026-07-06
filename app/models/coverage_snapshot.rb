class CoverageSnapshot < ApplicationRecord
  belongs_to :repository
  belongs_to :workflow
  belongs_to :job, optional: true

  after_initialize do
    self.data ||= {} if has_attribute?(:data)
  end

  scope :for_branch, ->(branch) { where(branch: branch) }
  scope :on_branch, ->(branch) { where(branch: branch) }
  scope :since, ->(time) { where(created_at: time..) }
  scope :recent, ->(n) { order(created_at: :desc).limit(n) }
  scope :on_default_branch, -> {
    joins(:repository).where("coverage_snapshots.branch = repositories.default_branch")
  }

  # Returns an array of ActiveRecord objects with date, avg_lines_pct,
  # avg_branches_pct, avg_functions_pct — grouped by calendar day on the
  # repository's default branch over the past +days+ days.
  def self.daily_averages(repository:, days: 30)
    on_branch(repository.default_branch)
      .since(days.days.ago)
      .group("DATE(created_at)")
      .select(
        "DATE(created_at) AS date",
        "AVG(lines_pct) AS avg_lines_pct",
        "AVG(branches_pct) AS avg_branches_pct",
        "AVG(functions_pct) AS avg_functions_pct"
      )
      .order(Arel.sql("DATE(created_at) ASC"))
  end
end
