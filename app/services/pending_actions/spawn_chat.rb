module PendingActions
  class SpawnChat < Base
    action_key "spawn_chat"
    requires_chat_session!

    MAX_CHATS = Mcp::Tools::SpawnChatsTool::MAX_CHATS

    def execute
      progress!("Creating chat...")
      result = ChatSessions::Creator.new(
        user: user,
        prompt: payload.fetch("prompt"),
        repository: target_repository,
        provider: payload["provider"],
        title: payload["title"]
      ).call
      spawned = result.chat_session
      bridge_thread = ChatBridgeThread.create!(
        origin_chat_session: chat_session,
        target_chat_session: spawned,
        opened_by_user: user,
        max_hops: ChatBridgeThread::DEFAULT_MAX_HOPS
      )
      action.update!(payload: payload.merge(
        "spawned_chat_id" => spawned.id,
        "spawned_chat_provider" => spawned.chat_provider,
        "spawned_chat_title" => spawned.title,
        "bridge_thread_id" => bridge_thread.id
      ))
      spawned
    end

    def execution_label = "Creating chat..."

    def validate_payload(errors)
      errors.add(:payload, "prompt is required") if payload["prompt"].blank?
      batch_size = Integer(payload["batch_size"], exception: false)
      errors.add(:payload, "batch_size must be between 1 and #{MAX_CHATS}") unless batch_size&.between?(1, MAX_CHATS)
      errors.add(:payload, "provider is unknown") if payload["provider"].present? && !User.chat_providers.include?(payload["provider"])
      errors.add(:payload, "repository is not accessible") if payload["repository_id"].present? && !accessible_repositories.exists?(id: payload["repository_id"])
      if action.pending_action_group && action.new_record? && action.pending_action_group.chat_pending_actions.where(action: "spawn_chat").count >= MAX_CHATS
        errors.add(:payload, "group cannot contain more than #{MAX_CHATS} chats")
      end
    end

    def action_detail
      [ payload["provider"], payload["title"].presence || payload["prompt"].to_s.truncate(60) ].compact.join(": ")
    end

    def presentation_label = "Spawn chat"

    def tool_card_outcome
      members = (action.pending_action_group&.chat_pending_actions || [ action ]).sort_by(&:id)
      chat_ids = members.filter_map { |member| Integer(member.payload.to_h["spawned_chat_id"], exception: false) }
      chat_ids.any? ? { chat_ids: chat_ids } : nil
    end

    private

    def target_repository
      return chat_session.repository if payload["repository_id"].blank?

      accessible_repositories.find(payload["repository_id"])
    end

    def accessible_repositories
      Repository.accessible_to(user).active
    end
  end
end
