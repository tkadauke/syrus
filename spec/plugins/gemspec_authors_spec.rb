require "rails_helper"

RSpec.describe "Plugin gemspec authors" do
  Dir.glob(Rails.root.join("plugins/*/*.gemspec")).sort.each do |gemspec_path|
    relative_path = Pathname.new(gemspec_path).relative_path_from(Rails.root).to_s

    it "sets a real author on #{relative_path}" do
      spec = Gem::Specification.load(gemspec_path)

      expect(spec).not_to be_nil, "#{relative_path} failed to load as a gemspec"
      expect(spec.authors).not_to be_empty, "#{relative_path} has no authors set"
      expect(spec.authors).to all(be_present), "#{relative_path} has a blank author"
      expect(spec.authors.map(&:downcase)).not_to include("syrus"),
        "#{relative_path} lists \"Syrus\" as an author, which is not a valid plugin author"
    end
  end
end
