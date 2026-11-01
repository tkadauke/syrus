module Coworkers
  module ChatExtension
    def self.install_into(scope)
      scope.effect("chat coworker resolver") do
        unless ChatSession.reflect_on_association(:coworker_chat)
          ChatSession.has_one :coworker_chat,
            class_name: "Coworkers::Chat",
            foreign_key: :chat_session_id,
            inverse_of: :chat_session
        end

        ChatSession.define_method(:coworker) do
          active = current_turn_message_id && messages.find_by(id: current_turn_message_id)
          rostered = active && coworker_roster_mention(active)
          rostered || coworker_chat&.coworker || ::Coworker::Syrus.for(user)
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
          next unless coworker_chat

          Coworkers::WorkspaceFileReadPolicy.for(relative_path)
        end

        ChatSession.define_method(:agent_turn_admission) do |message|
          agent = agent_turn_context(message).coworker
          next {} unless agent.respond_to?(:kind) && agent.kind == "coworker"

          Coworkers::PrivilegedGrantGate.turn_admission(agent)
        end

        ChatSession.define_method(:coworker_workspace?) do
          coworker_chat.present?
        end

        ChatSession.define_method(:coworker_workspace_repository_id) do
          coworker_workspace_repository&.id
        end

        ChatSession.define_method(:coworker_workspace_repository) do
          linked_coworker = coworker_chat&.coworker
          next unless linked_coworker

          if association(:repository_attachments).loaded?
            attached = repository_attachments.filter_map(&:attachable)
            matched = attached.find { |repository| repository.remote_url == linked_coworker.workspace_repo }
            next matched if matched
          end

          linked_coworker.workspace_repository
        end

        -> do
          %i[coworker coworker_roster_mention agent_turn_context with_agent_operation_lock workspace_file_read_policy agent_turn_admission coworker_workspace? coworker_workspace_repository coworker_workspace_repository_id].each do |method|
            ChatSession.remove_method(method) if ChatSession.instance_methods(false).include?(method)
          end
        end
      end
    end
  end
end
