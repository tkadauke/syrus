module VideoWalkthroughs
  class SlugType
    include Syrus::Plugin::SlugType

    def self.prefix = "WALKTHROUGH"
    def self.display_label = "Walkthrough"
    def self.preview_available? = false

    def self.client_path(id)
      "/s/#{canonical_slug(id)}"
    end

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
