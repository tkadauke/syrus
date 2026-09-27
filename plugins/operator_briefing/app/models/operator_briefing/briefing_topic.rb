module OperatorBriefing
  class BriefingTopic < ApplicationRecord
    self.table_name = "operator_briefing_topics"

    belongs_to :repository
    belongs_to :first_seen_briefing_item, class_name: "OperatorBriefing::BriefingItem", optional: true
    has_many :revisions, class_name: "OperatorBriefing::BriefingTopicRevision", foreign_key: :topic_id, dependent: :destroy
    has_many :topic_links, class_name: "OperatorBriefing::BriefingTopicLink", foreign_key: :topic_id, dependent: :destroy

    validates :slug, :title, presence: true
    validates :slug, uniqueness: { scope: :repository_id }
    normalizes :slug, with: ->(value) { value.to_s.parameterize.presence }

    def latest_revision
      revisions.order(revision_number: :desc, id: :desc).first
    end
  end
end
