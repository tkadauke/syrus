module Features
  class SyncFromYaml
    CONFIG_PATH = FeatureRegistry::CONFIG_PATH

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
      FeatureRegistry.declarations(config_path: config_path).map(&:to_h)
    end

    private

    attr_reader :config_path
  end
end
