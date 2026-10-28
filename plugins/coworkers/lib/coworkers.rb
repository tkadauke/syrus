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
    provides mentionable: "Coworkers::MentionableProvider"

    always { |scope| Coworkers::DataCleanup.install_into(scope) }
    while_enabled { |scope| Coworkers::ChatExtension.install_into(scope) }
  end
end
