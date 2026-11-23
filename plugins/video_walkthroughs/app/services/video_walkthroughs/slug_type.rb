module VideoWalkthroughs
  # Behavior for the `slug_type` manifest declaration in video_walkthroughs.rb,
  # which owns the prefix and label.
  class SlugType
    def self.record_for(id, user:)
      return nil unless user

      VideoWalkthroughs::Walkthrough
        .where(chat_session_id: user.accessible_chat_sessions.select(:id))
        .find_by(id: id)
    end

    def self.web_path(record)
      "/chats/#{record.chat_session_id}#walkthrough-#{record.id}"
    end
  end
end
