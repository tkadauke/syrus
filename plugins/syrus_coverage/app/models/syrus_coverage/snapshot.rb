class SyrusCoverage::Snapshot < ApplicationRecord
  self.table_name = "syrus_coverage_snapshots"

  belongs_to :repository, class_name: "::Repository"
  belongs_to :workflow, class_name: "::Workflow"
  belongs_to :job, class_name: "::Job", optional: true

  after_initialize do
    self.data ||= {} if has_attribute?(:data)
  end

  scope :on_branch, ->(branch) { where(branch: branch) }
  scope :for_project, ->(project_id) {
    id = project_id.presence || SyrusCoverage.root_project_id
    id == SyrusCoverage.root_project_id ? where(project_id: [ nil, SyrusCoverage.root_project_id ]) : where(project_id: id)
  }
  scope :since, ->(time) { where(created_at: time..) }
  scope :recent, ->(n) { order(created_at: :desc).limit(n) }
  scope :on_default_branch, -> {
    joins(:repository).where("syrus_coverage_snapshots.branch = repositories.default_branch")
  }

  # Returns an array of ActiveRecord objects with date, avg_lines_pct,
  # avg_branches_pct, avg_functions_pct — grouped by calendar day on the
  # repository's default branch over the past +days+ days.
  def self.daily_averages(repository:, days: 30)
    for_project(SyrusCoverage.root_project_id)
      .on_branch(repository.default_branch)
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
