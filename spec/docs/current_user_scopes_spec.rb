require "rails_helper"

RSpec.describe "Current.user scope audit" do
  AUDIT_PATH = Rails.root.join("docs/current-user-scopes.md")
  # Plugin controllers are in scope too: a controller that moves into a plugin
  # is still serving user data, and dropping it from the audit would let the
  # extraction program quietly erode this coverage.
  SCAN_GLOBS = [
    "app/controllers/**/*.rb",
    "app/views/**/*.erb",
    "plugins/*/app/controllers/**/*.rb"
  ].freeze

  def documented_scope_files
    audit = AUDIT_PATH.read
    yaml = audit.match(/```yaml current_user_scope_files\n(?<yaml>.*?)\n```/m)["yaml"]
    YAML.safe_load(yaml).values.flatten.uniq.reject { |path| uninstalled_plugin_file?(path) }
  end

  # A plugin can be uninstalled outright (that is what bin/plugin-boundary-audit
  # does to prove it), which takes its controllers with it. Documented entries
  # for a plugin that is not installed are skipped rather than reported as
  # stale -- entries for a plugin that *is* installed stay strict.
  def uninstalled_plugin_file?(path)
    plugin = path[%r{\Aplugins/([^/]+)/}, 1]
    return false if plugin.nil?

    !Rails.root.join("plugins", plugin).directory?
  end

  it "classifies every app file that references Current.user" do
    referenced_files = SCAN_GLOBS.flat_map { |glob| Rails.root.glob(glob) }
      .select { |path| path.read.include?("Current.user") }
      .map { |path| path.relative_path_from(Rails.root).to_s }
      .sort

    expect(documented_scope_files.sort).to eq(referenced_files)
  end
end
