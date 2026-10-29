require "delegate"

class Coworkers::TurnChatContext < SimpleDelegator
  attr_reader :coworker

  def initialize(chat, coworker)
    super(chat)
    @coworker = coworker
    @repository = coworker.workspace_repository
  end

  def effective_chat_provider
    coworker.chat_provider.presence || coworker.owner_user.effective_chat_provider
  end

  def chat_provider = effective_chat_provider
  def chat_model = coworker.chat_model
  def chat_effort = coworker.chat_effort
  attr_reader :repository
  def ephemeral_agent_turn? = true
end
