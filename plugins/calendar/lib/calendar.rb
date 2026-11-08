module Calendar
  extend Syrus::PluginApi

  syrus_plugin "calendar" do
    display_name "Calendar"
    description "A read-only operations calendar for planned work and observed executions."
    long_description "Calendar combines authorization-safe event sources into week and agenda views. Sources retain ownership of their data and actions; Calendar only presents and links to them."
    homepage "https://github.com/tkadauke/syrus"
    author "Thomas Kadauke"
    category "observability"
    icon_url "/plugin-icons/calendar.svg"
    default_enabled true
    disableable true
    hosts :event_source
    provides sidebar_page: "Calendar::SidebarPages",
      "calendar:event_source": [ "Calendar::Sources::RecurringMaintenance", "Calendar::Sources::ChatWakeups" ]
    route :get, "/api/v1/app/calendar/events", to: "api/v1/app/calendar/events#index"
    frontend routes: { "calendar/Calendar" => "app/frontend/routes/Calendar.tsx" },
      i18n: [ "app/frontend/i18n/locales/*/calendar.json" ]
  end
end
