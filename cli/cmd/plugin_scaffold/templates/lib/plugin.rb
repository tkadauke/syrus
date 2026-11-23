module {{MODULE_NAME}}
  extend Syrus::PluginApi

  syrus_plugin "{{PLUGIN_NAME}}" do
    version "0.1.0"
    default_enabled true
    disableable true
    experimental false
    requires_syrus ">= {{SYRUS_VERSION}}"
    display_name "{{DISPLAY_NAME}}"
    category "tooling"
    author "Your name"
    description "{{DISPLAY_NAME}} plugin for Syrus."

    provides callbacks: "{{MODULE_NAME}}::Callbacks"
{{OPTIONAL_PROVIDERS}}{{OPTIONAL_CLI}}
    frontend {{FRONTEND_DECLARATION}}
  end
end
