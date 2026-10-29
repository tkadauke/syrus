module Coworkers
  module ChatExtension
    def self.install_into(scope)
      scope.effect("chat coworker resolver") do
        ChatSession.define_method(:coworker) do
          Coworkers::Chat.includes(:coworker).find_by(chat_session_id: id)&.coworker || ::Coworker::Syrus.for(user)
        end

        ChatSession.define_method(:workspace_file_read_policy) do |relative_path|
          next unless Coworkers::Chat.exists?(chat_session_id: id)

          Coworkers::WorkspaceFileReadPolicy.for(relative_path)
        end

        lambda do
          ChatSession.remove_method(:coworker) if ChatSession.instance_methods(false).include?(:coworker)
          if ChatSession.instance_methods(false).include?(:workspace_file_read_policy)
            ChatSession.remove_method(:workspace_file_read_policy)
          end
        end
      end
    end
  end
end
