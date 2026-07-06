class CoverageSnapshot < ApplicationRecord
  belongs_to :repository
  belongs_to :workflow
  belongs_to :job, optional: true

  after_initialize do
    self.data ||= {}
  end

  scope :for_branch, ->(branch) { where(branch: branch) }
  scope :recent, ->(n) { order(created_at: :desc).limit(n) }
  scope :on_default_branch, -> {
    joins(:repository).where("coverage_snapshots.branch = repositories.default_branch")
  }
end
