class SyncAgentSkillsJob < ApplicationJob
  queue_as :default

  def perform
    AgentSkillsSyncer.sync
  end
end
