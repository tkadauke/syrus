module OperatorBriefing
  class Briefing < ApplicationRecord
    self.table_name = "operator_briefing_briefings"

    belongs_to :job
    belongs_to :repository
    belongs_to :owner_user, class_name: "User"
    has_many :revisions, class_name: "OperatorBriefing::BriefingRevision", dependent: :destroy
    has_many :items, class_name: "OperatorBriefing::BriefingItem", dependent: :destroy

    validates :job_id, uniqueness: true
    validates :window_start, presence: true
    validates :window_end, presence: true

    scope :for_owner, ->(user) { where(owner_user: user) }
    scope :for_repository, ->(repository) { where(repository: repository) }

    def live? = !job.closed?

    def latest_revision
      revisions.order(revision_number: :desc, id: :desc).first
    end
  end
end
