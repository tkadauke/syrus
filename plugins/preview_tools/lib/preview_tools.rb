module PreviewTools
  extend Syrus::PluginApi

  syrus_plugin "preview_tools" do
    display_name "Preview Tools"
    description "Scratch-directory-scoped write/edit tools plus show_preview/close_preview " \
      "so planning-mode chat agents can build and preview an HTML/CSS/JS mockup " \
      "or interactive widget without ever touching the attached repository checkout."
    long_description "Preview Tools gives planning-mode chat agents a safe scratch area for building lightweight HTML, CSS, and JavaScript previews. The tools are scoped away from repository checkouts, so agents can mock up ideas and show interactive artifacts without modifying project code.\n\nUse this plugin when chat should support exploratory UI sketches before a real job is filed. It is intentionally separate from repository preview providers, which run actual application code from workflow workspaces."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/preview_tools.svg"
    author "Thomas Kadauke"
    category "agent_capability"
    default_enabled true
    disableable true
    provides chat_mcp_tool_set: "PreviewTools::ChatToolSet",
             chat_media_source: "PreviewTools::MediaSource"
  end
end
