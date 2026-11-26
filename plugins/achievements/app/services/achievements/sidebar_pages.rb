module Achievements
  class SidebarPages
    include Syrus::Host::SidebarPage

    def self.sidebar_pages
      return [] unless Achievements.enabled?
      return [] unless Syrus::Host::Current.user

      [
        {
          id: "achievements.collection",
          label: "Achievements",
          label_key: "achievements:nav_achievements",
          path: "/achievements",
          paths: [ "/achievements" ],
          component: "achievements/Achievements",
          order: 90
        }
      ]
    end
  end
end
