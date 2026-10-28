require "coworkers/data_cleanup"
require "coworkers/chat_extension"

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
             chat_prompt_injector: "Coworkers::PromptSection",
             sidebar_page: "Coworkers::SidebarPages",
             chat_list_group: "Coworkers::ChatListGroup",
             chat_payload_contributor: "Coworkers::PayloadContributor"
    route :get, "/api/v1/app/coworkers", to: "api/v1/app/coworkers#index"
    route :post, "/api/v1/app/coworkers", to: "api/v1/app/coworkers#create"
    route :post, "/api/v1/app/coworkers/test_remote", to: "api/v1/app/coworkers#test_remote"
    route :get, "/api/v1/app/coworkers/sidebar_badge", to: "api/v1/app/coworkers#sidebar_badge"
    route :get, "/api/v1/app/coworkers/:id", to: "api/v1/app/coworkers#show"
    route :post, "/api/v1/app/coworkers/:id/chats", to: "api/v1/app/coworkers#create_chat"
    frontend routes: {
          "coworkers/Coworkers" => "app/frontend/routes/Coworkers.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/coworkers.json" ]

    always { |scope| Coworkers::DataCleanup.install_into(scope) }
    while_enabled { |scope| Coworkers::ChatExtension.install_into(scope) }
  end
end
