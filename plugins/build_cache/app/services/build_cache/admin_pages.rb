module BuildCache
  class AdminPages
    include Syrus::Plugin::AdminPage

    def self.admin_pages
      [
        {
          id: "build_cache.admin",
          label: "Build Cache",
          label_key: "build_cache:nav_build_cache",
          path: "/admin/build_cache",
          paths: [ "/admin/build_cache" ],
          component: "build_cache/AdminBuildCache",
          group_id: "operations",
          order: 70
        }
      ]
    end
  end
end
