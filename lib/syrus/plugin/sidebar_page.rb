module Syrus
  module Plugin
    # Marker interface for plugin-provided sidebar pages.
    #
    # Providers registered as :sidebar_page expose .sidebar_pages metadata. The
    # host uses that metadata to add SPA routes and primary sidebar nav entries.
    module SidebarPage
    end
  end
end
