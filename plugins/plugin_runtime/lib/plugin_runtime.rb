require "plugin_runtime/service"

module PluginRuntime
  extend Syrus::PluginApi

  syrus_plugin "plugin_runtime" do
    display_name "Plugin Runtime"
    description "Runs the containers that container-backed plugins need."
    long_description "Some plugins are more than Ruby: they need a long-running service of their own, such as a git mirror. Plugin Runtime runs those services and tells their plugins where to reach them.\n\nOn a Docker Compose install it asks the runtime manager container to pull and start each enabled plugin's service, with no restart, and removes it again when the plugin is disabled. On Kubernetes you deploy those services yourself and give Syrus their addresses; the plugins find them the same way either way."
    homepage "https://github.com/tkadauke/syrus"
    author "Thomas Kadauke"
    category "tooling"
    default_enabled false
    disableable true

    # Container-backed plugins declare their service through this point:
    #
    #   provides "plugin_runtime:service" => "GitMirror::RuntimeService"
    #
    # See PluginRuntime::Service for the contract.
    hosts [ :service ]

    # The reconcile loop. PluginTickSchedulerJob only ticks enabled plugins, so
    # disabling this plugin stops it touching containers at all.
    tick_interval 1.minute
    provides callbacks: "PluginRuntime::Callbacks"
  end
end
