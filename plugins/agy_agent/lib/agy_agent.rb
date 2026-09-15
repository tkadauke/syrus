module SyrusAgyAgent
  extend Syrus::PluginApi

  syrus_plugin "agy_agent" do
    display_name "Antigravity Agent"
    description "Runs workflow turns through Antigravity."
    long_description "Antigravity Agent connects Syrus workflows to the agy CLI/provider adapter. It provides the workflow provider core for Antigravity-backed implementation, review, and repair runs while keeping the invocation environment isolated from the worker account."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/agy_agent.svg"
    author "Thomas Kadauke"
    category "agent_provider"
    default_enabled true
    disableable true
    provides agent_provider: "AgentProviders::Agy"
  end
end
