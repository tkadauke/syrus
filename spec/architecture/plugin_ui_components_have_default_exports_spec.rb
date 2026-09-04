require "rails_helper"

# Every plugin UI component the SPA loads must have a default export.
#
# The loaders in app/frontend/pluginSidebarPages.tsx and its four siblings
# resolve a registered `"<plugin>/<Component>"` key to a module and read
# `.default`, throwing at runtime when it is missing. Nothing else catches
# that: a named-only export is valid TypeScript, the component's own tests
# import the named export directly, and the whole suite stays green. The
# failure appears when a user navigates to the page, as a browser error:
#
#   Plugin sidebar component global_search/Search has no default export
#
# Extracting routes into plugins broke four pages this way at once
# (global_search/Search, terminal/Terminal, agent_insights/AdminInsights,
# build_cache/AdminBuildCache), and search was the one someone happened to
# open.
RSpec.describe "plugin UI components" do
  # Directory per loader, mirroring each one's import.meta.glob.
  COMPONENT_DIRS = %w[routes repo_tabs workspaceTabs ui_slots].freeze

  # `component: "global_search/Search"` in any plugin's Ruby registration.
  REGISTRATION = /component:\s*["']([\w.]+)\/(\w+)["']/

  def registered_components
    Dir[Rails.root.join("plugins/*/**/*.rb")].flat_map do |path|
      File.read(path).scan(REGISTRATION).map { |plugin, component| [ plugin, component, path ] }
    end.uniq { |plugin, component, _| [ plugin, component ] }
  end

  def component_file(plugin, component)
    COMPONENT_DIRS.lazy.filter_map do |dir|
      candidate = Rails.root.join("plugins", plugin, "app/frontend", dir, "#{component}.tsx")
      candidate if candidate.exist?
    end.first
  end

  it "finds the registrations it is meant to check" do
    expect(registered_components.size).to be >= 5
  end

  it "resolve to a file the loaders can glob" do
    missing = registered_components.reject { |plugin, component, _| component_file(plugin, component) }

    expect(missing).to be_empty,
      "registered but no matching .tsx under #{COMPONENT_DIRS.join(', ')}:\n  " +
      missing.map { |plugin, component, path| "#{plugin}/#{component} (#{path})" }.join("\n  ")
  end

  it "all have a default export" do
    without = registered_components.filter_map do |plugin, component, _|
      file = component_file(plugin, component)
      next if file.nil?

      "#{plugin}/#{component} -> #{file.relative_path_from(Rails.root)}" unless File.read(file).match?(/^export default\b/)
    end

    expect(without).to be_empty, <<~MSG
      These plugin UI components are registered but export no default, so the
      SPA throws "has no default export" when a user opens them:
        #{without.join("\n  ")}
      Add `export default <Component>` to each.
    MSG
  end
end
