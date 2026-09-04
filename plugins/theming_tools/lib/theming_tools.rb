module ThemingTools
  extend Syrus::PluginApi

  syrus_plugin "theming_tools" do
    display_name "Theming Tools"
    description "Gives the Syrus Chat agent tools to draft, preview, install, and manage custom color " \
      "themes: preview_theme shows a candidate theme against the real Style Guide page, " \
      "install_theme persists one as the user's active theme (with a WCAG AA contrast " \
      "check), and list_user_themes/update_user_theme/delete_user_theme manage the user's " \
      "own custom themes. Experimental and off by default."
    long_description "Theming Tools gives the Syrus Chat agent tools to draft, preview, install, and " \
      "manage custom color themes: preview_theme shows a candidate theme against the real " \
      "Style Guide page, install_theme persists one as the user's active theme (with a " \
      "WCAG AA contrast check), and list_user_themes/update_user_theme/delete_user_theme " \
      "manage the user's own custom themes.\n\nThe underlying Theme model stays in core " \
      "(same precedent as WhiteboardSnapshot for whiteboard_tools) -- this plugin only owns " \
      "the tool surface and the broadcast wiring that opens the preview and performs " \
      "install/CRUD operations."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/theming_tools.svg"
    author "Thomas Kadauke"
    category "mcp_tool_set"
    default_enabled false
    disableable true
    provides chat_mcp_tool_set: "ThemingTools::ChatToolSet"
  end
end
