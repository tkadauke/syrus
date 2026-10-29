require "coworkers/data_cleanup"
require "coworkers/chat_extension"
require "coworkers/search_extension"

module Coworkers
  extend Syrus::PluginApi

  syrus_plugin "coworkers" do
    experimental true
    display_name "Coworkers"
    description "Persistent named agents with their own chats, capabilities, and workspace identity."
    long_description "Coworkers provides the data and policy foundation for persistent, user-owned agents. Each coworker has an instance-wide handle, explicit capability grants, a workspace remote, and one main chat plus optional side chats."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/coworkers.svg"
    author "Thomas Kadauke"
    category "agent_capability"
    default_enabled false
    disableable true
    depends_on [ "scheduled_tasks" ]
    provides mentionable: "Coworkers::MentionableProvider",
             chat_mcp_tool_set: "Coworkers::ChatToolSet",
             chat_result_decorator: "Coworkers::ChatResultDecorator",
             chat_prompt_injector: "Coworkers::PromptSection",
             sidebar_page: "Coworkers::SidebarPages",
             chat_list_group: "Coworkers::ChatListGroup",
             chat_payload_contributor: "Coworkers::PayloadContributor",
             chat_mcp_tool_set: "Coworkers::ChatToolSet"
    route :get, "/api/v1/app/coworkers", to: "api/v1/app/coworkers#index"
    route :post, "/api/v1/app/coworkers", to: "api/v1/app/coworkers#create"
    route :post, "/api/v1/app/coworkers/test_remote", to: "api/v1/app/coworkers#test_remote"
    route :get, "/api/v1/app/coworkers/sidebar_badge", to: "api/v1/app/coworkers#sidebar_badge"
    route :get, "/api/v1/app/coworkers/:id", to: "api/v1/app/coworkers#show"
    route :get, "/api/v1/app/coworkers/:id/memory", to: "api/v1/app/coworkers#memory"
    route :post, "/api/v1/app/coworkers/:id/chats", to: "api/v1/app/coworkers#create_chat"
    route :post, "/api/v1/app/chats/:chat_id/agents/:id", to: "api/v1/app/coworkers#add_to_chat"
    route :delete, "/api/v1/app/chats/:chat_id/agents/:id", to: "api/v1/app/coworkers#remove_from_chat"
    frontend routes: {
          "coworkers/Coworkers" => "app/frontend/routes/Coworkers.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/coworkers.json" ]

    always { |scope| Coworkers::DataCleanup.install_into(scope) }
    while_enabled do |scope|
      Coworkers::ChatExtension.install_into(scope)
      Coworkers::SearchExtension.install_into(scope)
    end
  end
end
