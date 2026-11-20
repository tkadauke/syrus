class Coworkers::CreateSideChat
  def self.call(coworker:, user:, repository:)
    ApplicationRecord.transaction do
      session = ChatSession.create!(
        user: user, repository: repository,
        **coworker.chat_configuration
      )
      Coworkers::Chat.create!(coworker: coworker, chat_session: session, role: "side")
      session
    end
  end
end
