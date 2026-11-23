module GoogleWorkspace
  extend Syrus::PluginApi

  CALENDAR_SCOPE = "calendar.read".freeze
  MAIL_SCOPE = "mail.read".freeze

  syrus_plugin "google_workspace" do
    requires_syrus nil
    experimental true
    display_name "Google Workspace"
    display_name_i18n_key "google_workspace:plugin.display_name"
    description "Read Gmail and Google Calendar through a connected Google account."
    description_i18n_key "google_workspace:plugin.description"
    long_description "Connect an instance-supplied Google OAuth client and expose read-only Gmail and Google Calendar data through provider-neutral tools."
    long_description_i18n_key "google_workspace:plugin.long_description"
    category "tooling"
    author "Thomas Kadauke"
    default_enabled false
    disableable true
    depends_on [ "connected_accounts", "mail", "personal_calendar" ]
    provides "connected_accounts:provider" => [ {
      provider: "GoogleWorkspace::Provider",
      key: "google_workspace",
      display_name: "Google",
      settings_notice: "Register your own Google OAuth client and check Google's current verification policy. Only the client id and secret are configurable; Syrus pins Google's endpoints and separate read-only Gmail and Calendar scopes.",
      settings_notice_i18n_key: "google_workspace:settings.provider_notice",
      capabilities: %w[authorization exchange_code refresh revoke identity validate],
      callback_route: "/api/v1/app/connected_accounts/callback/google_workspace",
      supports_read_only: true,
      configuration: {
        managed: true,
        authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
        token_url: "https://oauth2.googleapis.com/token",
        revoke_url: "https://oauth2.googleapis.com/revoke",
        identity_url: "https://www.googleapis.com/calendar/v3/calendars/primary",
        validate_url: "https://www.googleapis.com/calendar/v3/calendars/primary",
        scope_catalog: [ CALENDAR_SCOPE, MAIL_SCOPE ],
        read_only_scopes: [ CALENDAR_SCOPE, MAIL_SCOPE ],
        api_origins: [ "https://www.googleapis.com/calendar/v3/", "https://gmail.googleapis.com/gmail/v1/" ]
      },
      scopes: [
        {
          key: CALENDAR_SCOPE,
          label: "Read Google Calendar events",
          risk: "medium",
          read_only: true,
          syrus_capabilities: [ "calendar.read@v1" ]
        },
        {
          key: MAIL_SCOPE,
          label: "Read Gmail messages",
          risk: "high",
          read_only: true,
          syrus_capabilities: [ "mail.read@v1" ]
        }
      ]
    } ]
    provides personal_calendar: "GoogleWorkspace::CalendarAdapter", key: :google_workspace,
      provisional: %i[list_events get_event]
    provides mail: "GoogleWorkspace::MailAdapter", key: :google_workspace,
      provisional: %i[search read_message]
    frontend i18n: [ "app/frontend/i18n/locales/*/google_workspace.json" ]
  end
end
