module Coworkers
  module MentionActivityProxy
    def proxied_agent_activity_chat
      links = Coworkers::Chat.where(source_chat_session_id: id, role: "mention")
        .includes(:chat_session).order(updated_at: :desc).to_a
      sessions = links.map(&:chat_session)
      busy_session_ids = live_mention_session_ids(sessions)
      link = links.find do |candidate|
        candidate.chat_session.turn_in_flight? || busy_session_ids.include?(candidate.chat_session_id)
      end
      link&.chat_session
    end

    private

    def live_mention_session_ids(sessions)
      return [] if sessions.empty?

      session_ids = sessions.map(&:id)
      session_ids_by_workdir = sessions.index_by { |session| session.workspace_root.to_s }
      live_agents = SpawnedProcess.live_agent
      processes = live_agents.where(chat_session_id: session_ids)
        .or(live_agents.where(workdir: session_ids_by_workdir.keys))
        .pluck(:chat_session_id, :workdir)

      processes.flat_map do |chat_session_id, workdir|
        [
          session_ids.include?(chat_session_id) ? chat_session_id : nil,
          session_ids_by_workdir[workdir]&.id
        ]
      end.compact.uniq
    end
  end

  module ChatExtension
    def self.install_into(scope)
      scope.effect("chat coworker resolver") do
        ChatSession.prepend(Coworkers::MentionActivityProxy) unless ChatSession < Coworkers::MentionActivityProxy
        Syrus::Host::ChatMessages.install_after_commit_on_create(Coworkers::MentionMessageCallback, :delegate_coworker_mention)
        unless ChatSession.reflect_on_association(:coworker_chat)
          ChatSession.has_one :coworker_chat,
            class_name: "Coworkers::Chat",
            foreign_key: :chat_session_id,
            inverse_of: :chat_session
        end

        ChatSession.define_method(:coworker) do
          coworker_chat&.coworker || ::Coworker::Syrus.for(user)
        end

        ChatSession.define_method(:ephemeral_agent_turn?) { coworker_chat.present? }

        ChatSession.define_method(:owner_facing_chat_session) do
          link = Coworkers::Chat.find_by(chat_session_id: id)
          link&.mention? ? link.source_chat_session : self
        end

        ChatSession.define_method(:workspace_file_read_policy) do |relative_path|
          next unless coworker_chat

          Coworkers::WorkspaceFileReadPolicy.for(relative_path)
        end

        ChatSession.define_method(:coworker_grant_availability) do |capability|
          descriptor = Coworkers::GrantCatalog.all.find { |entry| entry.name == capability.to_s }
          next unless descriptor

          availability = Coworkers::PrivilegedGrantGate.availability(descriptor)
          { available: availability.available?, reason: availability.reason }
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
          Syrus::Host::ChatMessages.remove_after_commit_on_create(:delegate_coworker_mention)
          %i[coworker ephemeral_agent_turn? owner_facing_chat_session workspace_file_read_policy coworker_grant_availability coworker_workspace? coworker_workspace_repository coworker_workspace_repository_id].each do |method|
            ChatSession.remove_method(method) if ChatSession.instance_methods(false).include?(method)
          end
        end
      end
    end
  end
end
