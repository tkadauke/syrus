require "yaml"

class FeatureRegistry
  CONFIG_PATH = Rails.root.join("config/features.yml")

  Declaration = Data.define(
    :slug,
    :type,
    :default_enabled,
    :category,
    :name,
    :description,
    :operational_meaning,
    :name_i18n_key,
    :description_i18n_key
  ) do
    def to_h
      {
        slug: slug,
        type: type,
        default_enabled: default_enabled,
        category: category,
        name: name,
        description: description,
        operational_meaning: operational_meaning,
        name_i18n_key: name_i18n_key,
        description_i18n_key: description_i18n_key
      }
    end
  end

  def self.declarations(config_path: CONFIG_PATH)
    new(config_path: config_path).declarations
  end

  def initialize(config_path:)
    @config_path = Pathname.new(config_path)
  end

  def declarations
    raw_features.map do |raw|
      Declaration.new(
        slug: raw.fetch("slug").to_s,
        type: :boolean,
        default_enabled: ActiveModel::Type::Boolean.new.cast(raw.fetch("default", false)),
        category: raw.fetch("category").to_s,
        name: raw.fetch("name").to_s,
        description: raw["description"],
        operational_meaning: raw["operational_meaning"] || raw["description"],
        name_i18n_key: raw["name_i18n_key"],
        description_i18n_key: raw["description_i18n_key"]
      )
    end
  end

  private

  attr_reader :config_path

  def raw_features
    raw = YAML.safe_load(config_path.read) || {}
    features = raw.fetch("features", [])
    return features if features.is_a?(Array)

    raise ArgumentError, "config/features.yml features must be an array"
  end
end
