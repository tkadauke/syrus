require "rails_helper"

RSpec.describe "Bundled plugin family contract coverage" do
  it "runs each bundled family declaration through its generated shared examples" do
    missing = Syrus::PluginRegistry.all_plugins.filter_map do |manifest|
      next if manifest.external || Array(manifest.family_provides).empty?
      specs = Pathname.new(manifest.plugin_root).glob("spec/**/*_spec.rb").filter_map do |path|
        path.read if path.file?
      end.join("\n")
      families = manifest.family_provides.map(&:family).uniq
      uncovered = families.reject { |family| specs.include?(%("a valid #{family} provider")) }
      "#{manifest.name}: #{uncovered.join(', ')}" if uncovered.any?
    end

    expect(missing).to be_empty,
      "Bundled family declarations must use their generated shared examples: #{missing.join('; ')}"
  end
end
