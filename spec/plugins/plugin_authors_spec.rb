require "rails_helper"

RSpec.describe "Bundled plugin authors" do
  it "sets a real, non-blank author on every registered plugin" do
    manifests = Syrus::PluginRegistry.all_plugins
    expect(manifests).not_to be_empty

    manifests.each do |manifest|
      author = manifest.metadata[:author]

      expect(author).to be_present, "#{manifest.name} has no author set"
      expect(author.to_s.strip.downcase).not_to eq("syrus"),
        "#{manifest.name} lists \"Syrus\" as an author, which is not a valid plugin author"
    end
  end
end
