module Coworkers
  class RepositoryConfiguration
    include Syrus::Plugin::RepositoryConfiguration

    def self.key = "coworkers.review"
    def self.schema_version = 1
    def self.legacy_keys = [ "coworker_review" ]

    def self.parse(value:, version:, scope:)
      raise ArgumentError, "unsupported schema version #{version}" unless version == schema_version

      SyrusYml.parse_coworker_review_contribution(value)
    end

    def self.serialize(value:)
      return nil if value.nil?

      {
        "enabled" => value.enabled,
        "rounds" => value.rounds,
        "criteria" => value.criteria,
        "required" => value.required
      }
    end
  end
end
