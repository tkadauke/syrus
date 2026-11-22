module Mail
  extend Syrus::PluginApi

  Context = Data.define(:account, :access, :arguments)

  DEFINITION = Syrus::Host::CapabilityFamily.define(:mail) do
    shape :service
    capability :search, composition: :keyed, absent: :configuration_error, decline: nil,
      tier: :provisional, context: Mail::Context, returns: Hash
    capability :read_message, composition: :keyed, absent: :configuration_error, decline: nil,
      tier: :provisional, context: Mail::Context, returns: Hash
  end

  syrus_plugin "mail" do
    experimental true
    display_name "Mail"
    description "Provider-neutral, read-only mail search and message reading through connected accounts."
    category "tooling"
    author "Thomas Kadauke"
    default_enabled false
    disableable true
    depends_on [ "connected_accounts" ]
    provides mail: "Mail::FakeAdapter", key: :fake, provisional: %i[search read_message]
    provides chat_mcp_tool_set: "Mail::ChatToolSet",
             mcp_tool_set: "Mail::WorkflowToolSet",
             permission_provider: "Mail::PermissionProvider"
  end
end
