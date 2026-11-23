module ReviewPlanning
  # Owns the legacy bare-boolean `review_plan:` key. It is accepted so older
  # repositories stay valid, but it no longer changes any workflow.
  class RepositoryConfiguration
    include Syrus::Plugin::RepositoryConfiguration

    KEY = "review_planning.config".freeze

    def self.key = KEY
    def self.schema_version = 1
    def self.legacy_keys = [ "review_plan" ]

    def self.parse(value:, version:, scope:)
      raise ArgumentError, "unsupported schema version #{version}" unless version == schema_version

      ActiveModel::Type::Boolean.new.cast(value) || false
    end

    def self.serialize(value:) = value
  end
end
