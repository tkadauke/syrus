class ChatResultBadges
  def self.for(chat_sessions)
    sessions = Array(chat_sessions).compact.uniq(&:id)
    badges = sessions.to_h { |session| [ session.id, [] ] }
    return badges if sessions.empty?

    ChatIdentityContributions.status_contributions(chat_sessions: sessions, user: Current.user).each do |chat_session_id, contribution|
      badges.fetch(chat_session_id).concat(Array(contribution["badges"]))
    end

    badges
  end
end
