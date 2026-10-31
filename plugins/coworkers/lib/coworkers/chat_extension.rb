module Coworkers
  module ChatExtension
    def self.install_into(scope)
      scope.effect("chat coworker resolver") do
        ChatSession.define_method(:coworker) do
          active = current_turn_message_id && messages.find_by(id: current_turn_message_id)
          rostered = active && coworker_roster_mention(active)
          rostered || Coworkers::Chat.includes(:coworker).find_by(chat_session_id: id)&.coworker || ::Coworker::Syrus.for(user)
        end

        ChatSession.define_method(:coworker_roster_mention) do |message|
          mentions = Array(message.resolved_mentions)
          coworker_ids = mentions.filter_map { |mention| mention["id"] if mention["kind"] == "coworker" }
          rostered = Coworkers::ChatAgent.where(chat_session_id: id, coworker_id: coworker_ids).includes(:coworker).index_by(&:coworker_id)
          coworker_ids.lazy.filter_map { |coworker_id| rostered[coworker_id]&.coworker }.first
        end

        ChatSession.define_method(:agent_turn_context) do |message|
          rostered = coworker_roster_mention(message)
          rostered ? Coworkers::TurnChatContext.new(self, rostered) : self
        end

        ChatSession.define_method(:with_agent_operation_lock) do |message, &block|
          agent = agent_turn_context(message).coworker
          return block.call unless agent.respond_to?(:kind) && agent.kind == "coworker"

          Coworkers::OperationLock.with(agent, wait: 30.minutes.to_i, &block)
        end

        ChatSession.define_method(:workspace_file_read_policy) do |relative_path|
          next unless Coworkers::Chat.exists?(chat_session_id: id)

          Coworkers::WorkspaceFileReadPolicy.for(relative_path)
        end

        ChatSession.define_method(:execution_workload_policy) do
          agent = coworker
          agent.respond_to?(:execution_workload_policy) ? agent.execution_workload_policy : nil
        end

        ChatSession.define_method(:coworker_workspace?) do
          Coworkers::Chat.exists?(chat_session_id: id)
        end

        ChatSession.define_method(:coworker_workspace_repository_id) do
          association = Coworkers::Chat.includes(:coworker).find_by(chat_session_id: id)
          association&.coworker&.workspace_repository&.id
        end

        -> do
          %i[coworker coworker_roster_mention agent_turn_context with_agent_operation_lock workspace_file_read_policy execution_workload_policy coworker_workspace? coworker_workspace_repository_id].each do |method|
            ChatSession.remove_method(method) if ChatSession.instance_methods(false).include?(method)
          end
        end
      end
    end
  end
end
