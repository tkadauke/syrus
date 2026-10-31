module Coworkers
  module ChatExtension
    def self.install_into(scope)
      scope.effect("chat coworker resolver") do
        original_preloader = ChatSession.method(:preload_primary_repository_overrides)

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

        ChatSession.define_method(:coworker_workspace?) do
          Coworkers::Chat.exists?(chat_session_id: id)
        end

        ChatSession.define_method(:coworker_workspace_repository_id) do
          association = Coworkers::Chat.includes(:coworker).find_by(chat_session_id: id)
          association&.coworker&.workspace_repository&.id
        end

        ChatSession.define_method(:primary_repository_override) do
          return @primary_repository_override if instance_variable_defined?(:@primary_repository_override)

          association = Coworkers::Chat.includes(:coworker).find_by(chat_session_id: id)
          @primary_repository_override = association&.coworker&.workspace_repository
        end

        ChatSession.define_singleton_method(:preload_primary_repository_overrides) do |chat_sessions|
          sessions_by_id = Array(chat_sessions).index_by(&:id)
          links = Coworkers::Chat.includes(:coworker).where(chat_session_id: sessions_by_id.keys)
          coordinates_by_chat_id = links.to_h do |link|
            [ link.chat_session_id, link.coworker.workspace_repository_coordinates ]
          end
          coordinates = coordinates_by_chat_id.values.compact
          repositories_by_coordinates = if coordinates.empty?
            {}
          else
            owners, names = coordinates.transpose
            Repository
              .where("LOWER(owner) IN (?) AND LOWER(name) IN (?)", owners.uniq, names.uniq)
              .index_by { |repository| [ repository.owner.downcase, repository.name.downcase ] }
          end

          sessions_by_id.each do |chat_session_id, chat_session|
            repository = repositories_by_coordinates[coordinates_by_chat_id[chat_session_id]]
            chat_session.instance_variable_set(:@primary_repository_override, repository)
          end
        end

        -> do
          %i[coworker coworker_roster_mention agent_turn_context with_agent_operation_lock workspace_file_read_policy coworker_workspace? coworker_workspace_repository_id primary_repository_override].each do |method|
            ChatSession.remove_method(method) if ChatSession.instance_methods(false).include?(method)
          end
          ChatSession.define_singleton_method(:preload_primary_repository_overrides, original_preloader)
        end
      end
    end
  end
end
