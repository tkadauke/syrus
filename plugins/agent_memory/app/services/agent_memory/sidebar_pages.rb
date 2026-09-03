module AgentMemory
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    def self.sidebar_pages
      [
        {
          id: "agent_memory.memories",
          label: "Memories",
          label_key: "agent_memory:nav_memories",
          path: "/memories",
          paths: [ "/memories" ],
          component: "agent_memory/Memories",
          section: "settings",
          order: 70
        }
      ]
    end
  end
end
