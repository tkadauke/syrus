class Coworkers::CreateSideChat
  def self.call(coworker:, user:, repository:)
    ApplicationRecord.transaction do
      session = ChatSession.create!(
        user: user, repository: repository, title: coworker.name, title_auto_fallback: true,
        **coworker.chat_configuration
      )
      Coworkers::Chat.create!(coworker: coworker, chat_session: session, role: "side")
      session
    end
  end
end
