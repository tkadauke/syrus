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

    def append_block!(block)
      normalized = normalize_block(block)

      with_lock do
        update!(content_blocks: content_blocks + [ normalized ])
      end

      broadcast_block(normalized)
      normalized
    end

    private

    def content_blocks_are_supported
      content_blocks.each do |block|
        kind = block.respond_to?(:[]) ? block["kind"].presence || block[:kind] : nil
        errors.add(:content_blocks, "contains unsupported block kind #{kind.inspect}") unless BLOCK_KINDS.include?(kind.to_s)
      end
    end

    def normalize_block(block)
      hash = block.is_a?(Hash) ? block.deep_stringify_keys : {}
      hash.slice("kind", "payload").tap do |normalized|
        normalized["payload"] = normalized["payload"].is_a?(Hash) ? normalized["payload"] : {}
      end
    end

    def broadcast_block(block)
      AppEvents.broadcast(
        user: briefing.owner_user,
        type: "operator_briefing.block_submitted",
        resource: "operator_briefing",
        id: briefing_id,
        changed: [ "revision.content_blocks" ],
        payload: {
          briefing_id: briefing_id,
          revision_id: id,
          revision_number: revision_number,
          block: block
        }
      )
    end
  end
end
