module Whiteboard
  # What used to be `ChatSession has_one :whiteboard` and
  # `has_many :whiteboard_snapshots`, both `dependent: :destroy`, injected onto
  # the core model at boot.
  #
  # Installed with `always`, not `while_enabled`: disabling the plugin stops
  # the canvas being drawn on, it does not delete the boards and snapshots
  # already saved, and those still have to go when their chat does.
  module DataCleanup
    def self.install_into(scope)
      scope.effect("chat session boards") do
        Syrus::DataCleanup.register("ChatSession", "whiteboard.boards") do |chat_session|
          Whiteboard::Board.where(chat_session_id: chat_session.id).find_each(&:destroy)
        end
      end

      scope.effect("chat session snapshots") do
        Syrus::DataCleanup.register("ChatSession", "whiteboard.snapshots") do |chat_session|
          Whiteboard::Snapshot.where(chat_session_id: chat_session.id).find_each(&:destroy)
        end
      end
    end
  end
end
