require "rails_helper"

RSpec.describe Features::SyncFromYaml do
  def write_features_yaml(contents)
    path = Rails.root.join("tmp/features-#{SecureRandom.hex(4)}.yml")
    path.write(contents)
    path
  end

  it "creates declared features and initializes enabled from default" do
    path = write_features_yaml(<<~YAML)
      features:
        - slug: example_feature
          category: Example
          name: Example Feature
          description: An example feature.
          default: true
    YAML

    described_class.call(config_path: path)

    feature = Feature.find_by!(slug: "example_feature")
    expect(feature).to have_attributes(
      category: "Example",
      name: "Example Feature",
      description: "An example feature.",
      default_enabled: true,
      enabled: true
    )
  ensure
    path&.delete if path&.exist?
  end

  it "updates metadata and preserves operator enabled overrides" do
    path = write_features_yaml(<<~YAML)
      features:
        - slug: example_feature
          category: Example
          name: Example Feature
          description: First description.
          default: true
    YAML
    described_class.call(config_path: path)
    Feature.find_by!(slug: "example_feature").update!(enabled: false)

    path.write(<<~YAML)
      features:
        - slug: example_feature
          category: Updated
          name: Updated Feature
          description: Updated description.
          default: false
    YAML

    described_class.call(config_path: path)

    expect(Feature.find_by!(slug: "example_feature")).to have_attributes(
      category: "Updated",
      name: "Updated Feature",
      description: "Updated description.",
      default_enabled: false,
      enabled: false
    )
  ensure
    path&.delete if path&.exist?
  end

  it "does not delete features removed from YAML" do
    feature = Feature.create!(slug: "removed_feature", category: "Old", name: "Removed")
    path = write_features_yaml("features: []\n")

    described_class.call(config_path: path)

    expect(Feature.exists?(feature.id)).to be true
  ensure
    path&.delete if path&.exist?
  end

  it "no-ops gracefully on empty YAML" do
    path = write_features_yaml("features: []\n")

    expect { described_class.call(config_path: path) }.not_to change(Feature, :count)
  ensure
    path&.delete if path&.exist?
  end
end
