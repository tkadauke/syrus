module PersonalCalendar
  extend Syrus::PluginApi
  Context = Data.define(:account, :access, :arguments)
  DEFINITION = Syrus::Host::CapabilityFamily.define(:personal_calendar) do
    shape :service
    capability :list_events, composition: :keyed, absent: :configuration_error, decline: nil,
      tier: :provisional, context: PersonalCalendar::Context, returns: Hash
    capability :get_event, composition: :keyed, absent: :configuration_error, decline: nil,
      tier: :provisional, context: PersonalCalendar::Context, returns: Hash
  end
  syrus_plugin "personal_calendar" do
    requires_syrus nil
    experimental true
    display_name "Personal Calendar"
    description "Provider-neutral, read-only calendar access through connected accounts."
    icon_url "/plugin-icons/personal_calendar.svg"
    category "tooling"
    author "Thomas Kadauke"
    default_enabled false
    disableable true
    depends_on [ "connected_accounts" ]
    provides personal_calendar: "PersonalCalendar::FakeAdapter", key: :fake, provisional: %i[list_events get_event]
    provides chat_mcp_tool_set: "PersonalCalendar::ChatToolSet", mcp_tool_set: "PersonalCalendar::WorkflowToolSet",
      permission_provider: "PersonalCalendar::PermissionProvider"
  end
end
