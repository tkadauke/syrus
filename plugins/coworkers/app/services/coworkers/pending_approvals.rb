module Coworkers
  class PendingApprovals
    def initialize(owner:, coworker: nil)
      @owner = owner
      @coworker = coworker
    end

    def relation
      coworker_ids = Coworkers::Coworker.where(owner_user: owner)
      coworker_ids = coworker_ids.where(id: coworker.id) if coworker
      chat_ids = Coworkers::Chat.where(coworker_id: coworker_ids.select(:id)).select(:chat_session_id)

      ChatPendingAction.pending
        .where(user: owner, chat_session_id: chat_ids, action: "coworker_tool_call")
        .order(created_at: :asc, id: :asc)
    end

    def count = relation.count

    private

    attr_reader :owner, :coworker
  end
end
