module Mockups
  extend Syrus::PluginApi

  syrus_plugin "mockups" do
    display_name "Mockups"
    description "Scratch-directory-scoped write/edit tools plus show_preview/close_preview " \
      "so planning-mode chat agents can build and show an HTML/CSS/JS mockup " \
      "or interactive widget without ever touching the attached repository checkout."
    long_description "Mockups gives planning-mode chat agents a safe scratch area for building lightweight HTML, CSS, and JavaScript sketches. The tools are scoped away from repository checkouts, so agents can mock up ideas and show interactive artifacts without modifying project code.\n\nUse this plugin when chat should support exploratory UI sketches before a real job is filed. It is deliberately not the repository preview feature: those run actual application code from a workflow workspace, and this never touches the checkout."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/mockups.svg"
    author "Thomas Kadauke"
    category "agent_capability"
    default_enabled true
    disableable true
    provides chat_mcp_tool_set: "Mockups::ChatToolSet",
             chat_media_source: "Mockups::MediaSource",
             chat_payload_contributor: "Mockups::PayloadContributor",
             chat_prompt_injector: "Mockups::PromptSection"
  end
end
