require "agent_memory/data_cleanup"

module AgentMemory
  extend Syrus::PluginApi

  FILTER_CHIPS = {
    "content"       => "Filters::Chips::AgentMemory::Content",
    "scope"         => "Filters::Chips::AgentMemory::Scope",
    "kind"          => "Filters::Chips::AgentMemory::Kind",
    "repository_id" => "Filters::Chips::AgentMemory::RepositoryId",
    "published"     => "Filters::Chips::AgentMemory::Published",
    "created_at"    => "Filters::Chips::CreatedAt",
    "updated_at"    => "Filters::Chips::UpdatedAt"
  }.freeze

  syrus_plugin "agent_memory" do
    display_name "Agent Memory"
    description "Durable facts agents remember between runs, scoped per user and repository."
    long_description "Agent Memory is the store behind `write_memory` and its siblings: short, durable facts an agent records in one run and reads back in the next -- a user's preferences, a project decision, a correction worth not repeating.\n\nIt registers as Syrus's `memory_store`, which means it is swappable rather than merely optional: disable it and prompts simply carry no memory section, or replace it with a different store entirely."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/spqr_eagle.svg"
    author "Thomas Kadauke"
    category "mcp_tool_set"
    default_enabled true
    disableable true
    provides memory_store: "AgentMemory::Store",
             mcp_tool_set: "AgentMemory::McpToolSet",
             chat_mcp_tool_set: "AgentMemory::ChatToolSet",
             sidebar_page: "AgentMemory::SidebarPages"
    route :get, "/api/v1/app/memories", to: "api/v1/app/memories#index"
    route :post, "/api/v1/app/memories", to: "api/v1/app/memories#create"
    route :patch, "/api/v1/app/memories/:id", to: "api/v1/app/memories#update"
    route :delete, "/api/v1/app/memories/:id", to: "api/v1/app/memories#destroy"
    route :post, "/api/v1/app/memories/:id/publish", to: "api/v1/app/memories#publish"
    route :delete, "/api/v1/app/memories/:id/publish", to: "api/v1/app/memories#unpublish"
    route :get, "/api/v1/app/memories/:id/audit_events", to: "api/v1/app/memories#audit_events"
    frontend routes: { "agent_memory/Memories" => "app/frontend/routes/Memories.tsx" },
        i18n: [ "app/frontend/i18n/locales/*/agent_memory.json" ]

    while_enabled do |scope|
      scope.effect("memory filter subject") do
        Filters.register_subject(name: :memory, model: AgentMemory::Entry, chips: FILTER_CHIPS)
      end
    end

    # Rows this plugin owns on core records outlive it being disabled, and
    # still have to go when their owner does.
    always do |scope|
      AgentMemory::DataCleanup.install_into(scope)
    end
  end
end
