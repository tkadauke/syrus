# Sync built-in agent skills to ~/.claude/skills/ on app startup so every
# claude session on this host can invoke them. Runs on each deploy/restart,
# which is exactly when skills change — no separate watcher needed.
unless Rails.env.test?
  Rails.application.config.after_initialize do
    begin
      AgentSkillsSyncer.sync
    rescue StandardError => e
      Rails.logger.warn("[AgentSkillsSyncer] startup sync failed: #{e.class}: #{e.message}")
    end
  end
end
