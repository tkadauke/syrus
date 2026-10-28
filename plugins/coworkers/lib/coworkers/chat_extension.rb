module Coworkers
  module ChatExtension
    def self.install_into(scope)
      scope.effect("chat coworker resolver") do
        ChatSession.define_method(:coworker) do
          Coworkers::Chat.includes(:coworker).find_by(chat_session_id: id)&.coworker || ::Coworker::Syrus.for(user)
        end

        -> { ChatSession.remove_method(:coworker) if ChatSession.instance_methods(false).include?(:coworker) }
      end
    end
  end
end
