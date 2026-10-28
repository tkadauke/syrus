class ChatResultBadges
  def self.for(chat_sessions)
    sessions = Array(chat_sessions).compact.uniq(&:id)
    badges = sessions.to_h { |session| [ session.id, [] ] }
    return badges if sessions.empty?

    Syrus::PluginRegistry.providers_for(:chat_result_decorator).each do |provider|
      provider.chat_result_badges(chat_sessions: sessions).each do |chat_session_id, contributed_badges|
        id = chat_session_id.to_i
        badges[id].concat(Array(contributed_badges)) if badges.key?(id)
      end
    end

    badges
  end
end
