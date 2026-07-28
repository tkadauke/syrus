require "yaml"

module Features
  class SyncFromYaml
    CONFIG_PATH = Rails.root.join("config/features.yml")

    def self.call(config_path: CONFIG_PATH)
      new(config_path: config_path).call
    end

    def self.declarations(config_path: CONFIG_PATH)
      new(config_path: config_path).declarations
    end

    def self.build_time_asset_precompile?
      ENV["SECRET_KEY_BASE_DUMMY"].present?
    end

    def initialize(config_path:)
      @config_path = Pathname.new(config_path)
    end

    def call
      return unless Feature.table_exists?

      declarations.each do |declaration|
        feature = Feature.find_or_initialize_by(slug: declaration.fetch(:slug))
        feature.assign_attributes(
          category: declaration.fetch(:category),
          name: declaration.fetch(:name),
          description: declaration[:description],
          default_enabled: declaration.fetch(:default_enabled)
        )
        feature.enabled = feature.default_enabled if feature.new_record?
        feature.save!
      end
    end

    def declarations
      raw_features.map do |raw|
        {
          slug: raw.fetch("slug").to_s,
          category: raw.fetch("category").to_s,
          name: raw.fetch("name").to_s,
          description: raw["description"],
          default_enabled: ActiveModel::Type::Boolean.new.cast(raw.fetch("default", false)),
          name_i18n_key: raw["name_i18n_key"],
          description_i18n_key: raw["description_i18n_key"]
        }
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
end
