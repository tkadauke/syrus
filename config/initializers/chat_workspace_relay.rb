Rails.application.config.to_prepare do
  next unless SyrusVersion.server_process? && SyrusVersion.role == "worker"

  begin
    ChatWorkspaceRelay.start!
  rescue NameError
    # Zeitwerk autoloads not yet re-registered in this reload cycle;
    # the relay is already running from the previous cycle.
  end
end
