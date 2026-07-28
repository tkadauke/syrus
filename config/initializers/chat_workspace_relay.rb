Rails.application.config.to_prepare do
  next unless SyrusVersion.server_process? && SyrusVersion.role == "worker"

  ChatWorkspaceRelay.start!
end
