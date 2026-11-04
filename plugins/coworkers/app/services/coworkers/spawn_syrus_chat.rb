class Coworkers::SpawnSyrusChat
  def self.call(...) = new(...).call

  def initialize(coworker:, repository:, prompt:, title: nil, server_context:)
    @coworker = coworker
    @repository = repository
    @prompt = prompt.to_s.strip
    @title = title.to_s.strip.presence
    @origin_chat = server_context.fetch(:chat_session)
  end

  def call
    chat = nil
    thread = nil
    ApplicationRecord.transaction do
      chat = ChatSession.create!(
        user: @coworker.owner_user,
        repository: @repository,
        title: @title || ChatSession.fallback_title_for(@repository),
        last_message_at: Time.current,
        conversation_kind: "direct",
        artifacts: {
          "opened_by_coworker" => {
            "id" => @coworker.id,
            "handle" => @coworker.handle,
            "name" => @coworker.name
          }
        }
      )
      thread = ChatBridgeThread.create!(
        origin_chat_session: @origin_chat,
        target_chat_session: chat,
        opened_by_user: @coworker.owner_user
      )
      ChatSession::CrossChatMessage.new(thread:, text: @prompt, from: @origin_chat).deliver!
      Permissions::CoworkerAudit.record!(
        :coworker_syrus_chat_spawned,
        owner: @coworker.owner_user,
        coworker: @coworker,
        chat_session_id: chat.id,
        repository_id: @repository.id,
        bridge_thread_id: thread.id,
        **spawn_cap_audit
      )
    end
    { chat:, thread: }
  end

  private

  def spawn_cap_audit
    constraints = @coworker.grants.find_by(capability: "syrus.spawn_chat")&.constraints.to_h
    {
      max_spawns_per_run: constraints.fetch("max_spawns_per_run", Coworkers::SpawnSyrusChatTool::DEFAULT_PER_RUN_CAP),
      max_spawns_per_day: constraints.fetch("max_spawns_per_day", Coworkers::SpawnSyrusChatTool::DEFAULT_PER_DAY_CAP)
    }
  end
end
