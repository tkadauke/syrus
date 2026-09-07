require "rails_helper"

# A sidebar page is only reachable on client-side navigation if it lists its
# own path in `paths`, which is what React derives its routes from -- Rails
# no longer gates hard reload on it. `config/routes.rb` now serves the SPA
# shell for any non-API, non-Rails GET path (see the blanket `*path` route),
# so the reachability question these examples used to ask on Rails' behalf --
# "does this declared path route to spa#show" -- is answered unconditionally
# by that wildcard and no longer needs its own coverage here (see
# spec/requests/spa_spec.rb's "routes every React app route" example instead).
# What's still not automatic is the React half: a page whose `paths` omits its
# own path renders a blank shell on direct navigation even though Rails
# answered 200, and App.tsx must derive plugin routes rather than hardcode
# them -- both of those have been missed in practice (git_history's tab, then
# mockups and scheduled_tasks), so neither is left to anyone remembering.
RSpec.describe "plugin sidebar page routing" do
  # Read from source, not from the registry: a page in a plugin that happens
  # to be off in this environment gets no coverage from a registry-based
  # check at all. `terminal` declared `path:` and no `paths:`, contributing
  # nothing to React's route derivation, and reached its page purely because
  # core hand-wrote a route for it -- invisible here because the plugin is
  # disabled by default.
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
      "these sidebar pages do not list their own path in `paths`, so React " \
      "does not derive a client-side route for them: #{offenders.join(', ')}"
  end

  # `repository_plugin_spa` (the "repositories/:repository_id/plugin/*path"
  # host route and its `repo_page_tab_route?` constraint) was retired the same
  # way as the sidebar_page wildcard, for the same reason: the blanket route
  # below already serves any path of that shape, so gating it added nothing
  # but a false 404 for a tab a plugin forgot to register. A tab declaring
  # only `path` still reaches the shell, but React has no route to render
  # there -- the same failure mode the sidebar_page check above guards.
  it "declares every repo page tab's own path in its paths list" do
    offenders = Dir[Rails.root.join("plugins/*/app/services/*/repo_page_tabs.rb")].filter_map do |file|
      source = File.read(file)
      plugin = file.delete_prefix("#{Rails.root}/plugins/").split("/").first

      next if source.match?(/\bpaths:\s*\[/)

      plugin if source.match?(/\bpath:\s*"/)
    end

    expect(offenders).to eq([]),
      "these repo page tabs declare `path` without `paths`, so React does not derive a " \
      "client-side route for them: #{offenders.join(', ')}"
  end

  # This is the behavior change this file used to guard against: an
  # undeclared path used to 404. Now `config/routes.rb`'s blanket `*path`
  # route serves the SPA shell for any GET that isn't under /api or /rails,
  # on purpose -- see spec/requests/spa_spec.rb for the /api and /rails
  # exclusions.
  it "serves the SPA shell for a path no plugin declares" do
    recognized = Rails.application.routes.recognize_path("/definitely-not-a-plugin-page", method: :get)

    expect(recognized).to include(controller: "spa", action: "show")
  end

  # The React half derives its routes from the sidebar_page declarations at
  # runtime (see renderPluginSidebarRoutes in App.tsx). What core must NOT do
  # is carry its own copy of the list, which is what silently rotted before.
  it "keeps core's React route table free of plugin page paths" do
    app_tsx = Rails.root.join("app/frontend/routes/App.tsx").read
    declared_paths = Syrus::PluginRegistry.providers_for(:sidebar_page).flat_map do |provider|
      Array(provider.sidebar_pages).flat_map { |page| Array(page[:paths] || page["paths"]) }
    rescue StandardError
      []
    end.uniq
    hardcoded = declared_paths.select { |path| app_tsx.include?("path: \"#{path}\"") }

    expect(hardcoded).to eq([]),
      "App.tsx hardcodes plugin sidebar paths that it should derive from the " \
      "sidebar_page declarations instead: #{hardcoded.join(', ')}"
  end
end
