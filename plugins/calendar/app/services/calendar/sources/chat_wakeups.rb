module Calendar
  module Sources
    class ChatWakeups
      def self.calendar_events(user:, starts_at:, ends_at:)
        ChatWakeup.pending.where(user_id: user.id, fire_at: starts_at...ends_at).includes(:chat_session).map do |wakeup|
          Event.new(source_id: "calendar:chat_wakeups", id: "wakeup-#{wakeup.id}", kind: "chat_wakeup",
            title: wakeup.prompt.to_s.truncate(100), starts_at: wakeup.fire_at, destination_path: "/chats/#{wakeup.chat_session_id}",
            state: "pending", metadata: { chat_id: wakeup.chat_session_id })
        end
      end
    end
  end
end
