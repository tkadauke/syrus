# Durable, per-Job record of a provider PR opened for a specific purpose
# (`role`) as part of a delivery track. Forward-looking replacement for
# Job's overloaded single-purpose PR columns (`pr_number`,
# `external_pr_number`, `fork_review_pr_number`, `pr_repository_id`) — see
# config/syrus_docs/delivery_tracks.md. Written additively alongside those
# legacy columns; nothing reads from this model yet.
class JobPrLink < ApplicationRecord
  ROLE_LOCAL = "local".freeze
  ROLE_UPSTREAM_EXPORT = "upstream_export".freeze
  ROLE_PROMOTION = "promotion".freeze
  ROLE_HOTFIX_SYNC = "hotfix_sync".freeze
  ROLE_EXTERNAL_INGEST = "external_ingest".freeze

  ROLES = [ ROLE_LOCAL, ROLE_UPSTREAM_EXPORT, ROLE_PROMOTION, ROLE_HOTFIX_SYNC, ROLE_EXTERNAL_INGEST ].freeze

  belongs_to :job
  belongs_to :source_repository, class_name: "Repository", optional: true
  belongs_to :target_repository, class_name: "Repository", optional: true

  validates :role, presence: true, inclusion: { in: ROLES }
  validates :role, uniqueness: { scope: :job_id }

  after_initialize :default_metadata, if: :new_record?

  # Idempotent upsert: one link per (job, role). Later writes for the same
  # job/role (e.g. a retried pr_open) update the existing row in place
  # rather than raising on the uniqueness constraint.
  def self.record!(job:, role:, **attrs)
    link = find_or_initialize_by(job: job, role: role)
    link.assign_attributes(attrs)
    link.save!
    link
  end

  private

  def default_metadata
    self.metadata ||= {}
  end
end
