require "agent_memory/version"
require "agent_memory/host_associations"
require "agent_memory/engine"

module AgentMemory
  FILTER_CHIPS = {
    "content"       => "Filters::Chips::AgentMemory::Content",
    "scope"         => "Filters::Chips::AgentMemory::Scope",
    "kind"          => "Filters::Chips::AgentMemory::Kind",
    "repository_id" => "Filters::Chips::AgentMemory::RepositoryId",
    "published"     => "Filters::Chips::AgentMemory::Published",
    "created_at"    => "Filters::Chips::CreatedAt",
    "updated_at"    => "Filters::Chips::UpdatedAt"
  }.freeze

  def self.register!
    Filters.register_subject(name: :memory, model: AgentMemory::Entry, chips: FILTER_CHIPS)

    Syrus::PluginRegistry.register(
      name:            "agent_memory",
      display_name:    "Agent Memory",
      version:         AgentMemory::VERSION,
      default_enabled: true,
      disableable:     true,
      category:        "mcp_tool_set",
      description:     "Durable facts agents remember between runs, scoped per user and repository.",
      long_description: "Agent Memory is the store behind `write_memory` and its siblings: short, durable facts an agent records in one run and reads back in the next -- a user's preferences, a project decision, a correction worth not repeating.\n\nIt registers as Syrus's `memory_store`, which means it is swappable rather than merely optional: disable it and prompts simply carry no memory section, or replace it with a different store entirely.",
      homepage:        "https://github.com/tkadauke/syrus",
      icon_url:        "/plugin-icons/spqr_eagle.svg",
      author:          "Thomas Kadauke",
      frontend: {
        routes: { "agent_memory/Memories" => "app/frontend/routes/Memories.tsx" },
        i18n: [ "app/frontend/i18n/locales/*/agent_memory.json" ]
      },
      routes: [
        { verb: "GET",    path: "/api/v1/app/memories", controller: "api/v1/app/memories#index" },
        { verb: "POST",   path: "/api/v1/app/memories", controller: "api/v1/app/memories#create" },
        { verb: "PATCH",  path: "/api/v1/app/memories/:id", controller: "api/v1/app/memories#update" },
        { verb: "DELETE", path: "/api/v1/app/memories/:id", controller: "api/v1/app/memories#destroy" },
        { verb: "POST",   path: "/api/v1/app/memories/:id/publish", controller: "api/v1/app/memories#publish" },
        { verb: "DELETE", path: "/api/v1/app/memories/:id/publish", controller: "api/v1/app/memories#unpublish" },
        { verb: "GET",    path: "/api/v1/app/memories/:id/audit_events", controller: "api/v1/app/memories#audit_events" }
      ],
      provides: {
        memory_store:      AgentMemory::Store,
        mcp_tool_set:      AgentMemory::McpToolSet,
        chat_mcp_tool_set: AgentMemory::ChatToolSet,
        sidebar_page:      AgentMemory::SidebarPages
      }
    )
  end

  def self.enabled?
    Syrus::PluginRegistry.all_plugins.any? { |manifest| manifest.name == "agent_memory" && manifest.enabled? }
  end
end
