# Bundled plugin registration. Each plugin's register! method pushes its
# providers into Syrus::PluginRegistry at boot, making them available to
# the sidecar (mcp_tool_set) and the implement step (prompt_injector).
Rails.application.config.to_prepare do
  SyrusRails.register!
end
