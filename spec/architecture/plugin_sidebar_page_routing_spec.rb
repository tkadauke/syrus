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

  # Read from source, not from the registry: PluginRouteResolver only sees
  # *enabled* plugins, so a page in a plugin that happens to be off in this
  # environment gets no coverage from the example above at all. `terminal`
  # declared `path:` and no `paths:`, contributing nothing to either half, and
  # reached its page purely because core hand-wrote a route for it -- invisible
  # here because the plugin is disabled by default.
  it "declares every sidebar page's own path in its paths list" do
    offenders = Dir[Rails.root.join("plugins/*/app/services/*/sidebar_pages.rb")].flat_map do |file|
      source = File.read(file)
      plugin = file.delete_prefix("#{Rails.root}/plugins/").split("/").first

      source.split(/\n\s*\{\s*\n/).drop(1).filter_map do |page|
        path = page[/\bpath:\s*"([^"]+)"/, 1]
        next if path.nil?

        declared = page[/\bpaths:\s*\[(.*?)\]/m, 1].to_s.scan(/"([^"]+)"/).flatten
        "#{plugin} #{path}" unless declared.include?(path)
      end
    end

    expect(offenders).to eq([]),
      "these sidebar pages do not list their own path in `paths`, so neither Rails nor " \
      "React derives a route for them: #{offenders.join(', ')}"
  end

  # Repo tabs have the same shape and the same gate: repo_page_tab_route? is
  # what lets the "repositories/:repository_id/plugin/*path" wildcard serve the
  # shell, and it matches on `paths`. A tab declaring only `path` 404s on hard
  # reload -- which is precisely the git_history bug that extension point was
  # built to prevent, and git_history still had it.
  it "declares every repo page tab's own path in its paths list" do
    offenders = Dir[Rails.root.join("plugins/*/app/services/*/repo_page_tabs.rb")].filter_map do |file|
      source = File.read(file)
      plugin = file.delete_prefix("#{Rails.root}/plugins/").split("/").first

      next if source.match?(/\bpaths:\s*\[/)

      plugin if source.match?(/\bpath:\s*"/)
    end

    expect(offenders).to eq([]),
      "these repo page tabs declare `path` without `paths`, so the plugin route wildcard " \
      "cannot serve them and a hard reload 404s: #{offenders.join(', ')}"
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
