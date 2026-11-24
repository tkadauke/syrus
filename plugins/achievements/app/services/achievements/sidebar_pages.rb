module Achievements
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      return [] unless Achievements.enabled?
      return [] unless Current.user

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
