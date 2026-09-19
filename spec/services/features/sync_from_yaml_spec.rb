require "rails_helper"

RSpec.describe Features::SyncFromYaml do
  around do |example|
    original = ENV["SECRET_KEY_BASE_DUMMY"]
    example.run
  ensure
    ENV["SECRET_KEY_BASE_DUMMY"] = original
  end

  def write_features_yaml(contents)
    path = Rails.root.join("tmp/features-#{SecureRandom.hex(4)}.yml")
    path.write(contents)
    path
  end

  it "detects build-time asset precompile mode without touching the database" do
    ENV["SECRET_KEY_BASE_DUMMY"] = "1"

    expect(described_class.build_time_asset_precompile?).to be true
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

  it "parses name_i18n_key and description_i18n_key from YAML into declarations" do
    path = write_features_yaml(<<~YAML)
      features:
        - slug: example_feature
          category: Example
          name: Example Feature
          name_i18n_key: features.slugs.example_feature.name
          description: An example feature.
          description_i18n_key: features.slugs.example_feature.description
          default: false
        - slug: no_keys_feature
          category: Example
          name: No Keys
          default: false
    YAML

    declarations = described_class.declarations(config_path: path)

    expect(declarations.find { |d| d[:slug] == "example_feature" }).to include(
      type: :boolean,
      default_enabled: false,
      operational_meaning: "An example feature.",
      name_i18n_key: "features.slugs.example_feature.name",
      description_i18n_key: "features.slugs.example_feature.description"
    )
    expect(declarations.find { |d| d[:slug] == "no_keys_feature" }).to include(
      name_i18n_key: nil,
      description_i18n_key: nil
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

  it "does not silently re-enable coding_mode for an instance that " \
     "explicitly turned it off before its default flipped to true" do
    Feature.find_or_create_by!(slug: "coding_mode") do |feature|
      feature.category = "Labs"
      feature.name = "Coding Mode"
    end.update!(enabled: false)

    described_class.call

    feature = Feature.find_by!(slug: "coding_mode")
    expect(feature.default_enabled).to be(true), "expected coding_mode to now default to true in config/features.yml"
    expect(feature.enabled).to be(false), "expected the operator override for coding_mode to survive the default flip"
  end

  it "does not silently re-disable local_mode for an instance that " \
     "explicitly turned it on before its default flipped to false" do
    Feature.find_or_create_by!(slug: "local_mode") do |feature|
      feature.category = "Labs"
      feature.name = "Local Mode"
    end.update!(enabled: true)

    described_class.call

    feature = Feature.find_by!(slug: "local_mode")
    expect(feature.default_enabled).to be(false), "expected local_mode to default to false in config/features.yml"
    expect(feature.enabled).to be(true), "expected the operator override for local_mode to survive the default flip"
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
