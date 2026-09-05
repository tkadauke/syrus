require "rails_helper"

# A sidebar page is reachable only if three things agree: the plugin declares
# the path, Rails serves the SPA shell there, and React has a route for it.
# Both halves have been missed in practice -- git_history's tab, then mockups
# and scheduled_tasks -- so neither is left to anyone remembering.
#
# These examples deliberately assert the *mechanism*, not a list of paths. A
# list here would be the same coupling the mechanism exists to remove.
RSpec.describe "plugin sidebar page routing" do
  it "serves every path a plugin declares as the SPA shell" do
    unserved = PluginRouteResolver.declared_sidebar_paths.reject do |path|
      probe = path.gsub(/:[a-z_]+/, "1")
      Rails.application.routes.recognize_path(probe, method: :get)[:controller] == "spa"
    rescue StandardError
      false
    end

    expect(unserved).to eq([]),
      "these declared sidebar paths do not reach spa#show, so a hard reload 404s: #{unserved.join(', ')}"
  end

  it "does not turn into a blanket catch-all for undeclared paths" do
    expect { Rails.application.routes.recognize_path("/definitely-not-a-plugin-page", method: :get) }
      .to raise_error(ActionController::RoutingError)
  end

  # The React half derives its routes from the same declarations at runtime
  # (see renderPluginSidebarRoutes in App.tsx). What core must NOT do is carry
  # its own copy of the list, which is what silently rotted before.
  it "keeps core's React route table free of plugin page paths" do
    app_tsx = Rails.root.join("app/frontend/routes/App.tsx").read
    hardcoded = PluginRouteResolver.declared_sidebar_paths.select do |path|
      app_tsx.include?("path: \"#{path}\"")
    end

    expect(hardcoded).to eq([]),
      "App.tsx hardcodes plugin sidebar paths that it should derive from the " \
      "sidebar_page declarations instead: #{hardcoded.join(', ')}"
  end
end
