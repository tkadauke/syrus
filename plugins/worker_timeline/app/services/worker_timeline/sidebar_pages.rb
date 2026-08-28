module WorkerTimeline
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      return [] unless WorkerTimeline.enabled?
      return [] unless Current.user&.admin?

      [
        {
          id: "worker_timeline.macro",
          label: "Worker Timeline",
          label_key: "worker_timeline:nav_worker_timeline",
          path: "/worker_timeline",
          paths: [ "/worker_timeline", "/worker_timeline/workflow" ],
          component: "worker_timeline/WorkerTimeline",
          icon: "timeline",
          order: 80
        }
      ]
    end
  end
end
