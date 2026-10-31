module SyrusDev
  module DiagnosticsAuthorization
    private

    def coworker_diagnostics_authorized?(context)
      context.role == AgentRole::COWORKER_CHAT &&
        context.granted_capabilities.include?(ChatToolSet::CAPABILITY)
    end
  end
end
