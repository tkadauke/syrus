module Calendar
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      return [] unless Calendar.enabled?

      [ { id: "calendar", label: "Calendar", label_key: "calendar:nav", path: "/calendar",
          paths: [ "/calendar" ], component: "calendar/Calendar", icon: "calendar", order: 45 } ]
    end
  end
end
