module Syrus
  module Plugin
    # Marker interface for plugin-provided repository-page tabs.
    #
    # Providers registered as :repo_page_tab expose
    # .repo_page_tabs(repository:, user:) so a provider can compute
    # visibility per repo/user (unlike :admin_page, which is instance-wide).
    # The host uses that metadata to add SPA routes and repository tab
    # navigation entries.
    module RepoPageTab
    end
  end
end
