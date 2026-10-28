module Coworkers
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      [ {
        id: "coworkers.index", label: "Coworkers", label_key: "coworkers:nav",
        path: "/coworkers", paths: [ "/coworkers", "/coworkers/new", "/coworkers/:id" ],
        component: "coworkers/Coworkers", icon: "team",
        badge_api_path: "/api/v1/app/coworkers/sidebar_badge", order: 45
      } ]
    end
  end
end
