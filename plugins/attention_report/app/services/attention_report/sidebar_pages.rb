module AttentionReport
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      [
        {
          id: "attention_report.dashboard",
          label: "Attention Report",
          label_key: "attention_report:nav_attention_report",
          path: "/insights/attention",
          paths: [ "/insights/attention" ],
          component: "attention_report/AttentionReport",
          icon: "attention_report",
          order: 46
        }
      ]
    end
  end
end
