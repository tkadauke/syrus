module Syrus
  module Plugin
    # Marker interface for plugin-provided sidebar pages.
    #
    # Providers registered as :sidebar_page expose .sidebar_pages metadata. The
    # host uses that metadata to add SPA routes and nav entries.
    #
    # An optional `badge_api_path:` names an endpoint returning
    # `{"count": n}`; the chrome polls it and shows the number on the nav
    # entry, so a live count stays the plugin's business.
    #
    # An optional `section:` says which nav the page belongs to: "primary"
    # (the default) is the main sidebar; "settings" is the settings section's
    # own side nav, where a per-user, preferences-shaped page belongs.
    module SidebarPage
    end
  end
end
