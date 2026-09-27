module OperatorBriefing
  class BriefingRevision < ApplicationRecord
    self.table_name = "operator_briefing_revisions"

    BLOCK_KINDS = %w[narrative link_card].freeze

    belongs_to :briefing, class_name: "OperatorBriefing::Briefing"
    belongs_to :generation_run, class_name: "Run", optional: true

    validates :revision_number, presence: true, numericality: { only_integer: true, greater_than: 0 }
    validates :revision_number, uniqueness: { scope: :briefing_id }
    validates :generated_at, presence: true
    validate :content_blocks_are_supported

    def content_blocks
      Array(super)
    end

    private

    def content_blocks_are_supported
      content_blocks.each do |block|
        kind = block.respond_to?(:[]) ? block["kind"].presence || block[:kind] : nil
        errors.add(:content_blocks, "contains unsupported block kind #{kind.inspect}") unless BLOCK_KINDS.include?(kind.to_s)
      end
    end
  end
end
