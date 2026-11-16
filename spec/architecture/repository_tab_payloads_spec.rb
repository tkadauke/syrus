require "rails_helper"

RSpec.describe "repository tab payloads" do
  it "does not embed the repository tab catalog in page payloads" do
    controller_files = [
      Rails.root.join("app/controllers/**/*.rb"),
      Rails.root.join("plugins/*/app/controllers/**/*.rb")
    ].flat_map { |pattern| Dir.glob(pattern) }

    offenders = controller_files.filter_map do |path|
      relative_path = Pathname(path).relative_path_from(Rails.root).to_s
      relative_path if File.read(path).include?("repository_tabs_json")
    end

    expect(offenders).to be_empty,
      "repo-tab responses must load tabs from /repositories/:id/plugin_tabs; found embedded tabs in: #{offenders.join(', ')}"
  end
end
