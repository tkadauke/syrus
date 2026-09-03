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
    YAML.safe_load(yaml).values.flatten.uniq
  end

  it "classifies every app file that references Current.user" do
    referenced_files = SCAN_GLOBS.flat_map { |glob| Rails.root.glob(glob) }
      .select { |path| path.read.include?("Current.user") }
      .map { |path| path.relative_path_from(Rails.root).to_s }
      .sort

    expect(documented_scope_files.sort).to eq(referenced_files)
  end
end
