class SyncAgentSkillsJob < ApplicationJob
  include SkipIfPending

  queue_as :low_priority_maintenance

  def perform
    AgentSkillsSyncer.sync
  end
end
