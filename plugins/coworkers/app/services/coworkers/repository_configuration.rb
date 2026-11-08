module Coworkers
  # Owns the `.syrus.yml` coworker review schema. The legacy top-level
  # `coworker_review:` key is a plugin-owned compatibility alias for the
  # namespaced `plugins: { coworkers.review: ... }` envelope.
  class RepositoryConfiguration
    include Syrus::Plugin::RepositoryConfiguration

    MIN_ROUNDS = 1
    MAX_ROUNDS = 10

    Config = Data.define(:enabled, :rounds, :criteria, :required)

    def self.key = "coworkers.review"
    def self.schema_version = 1
    def self.legacy_keys = [ "coworker_review" ]

    def self.parse(value:, version:, scope:)
      raise ArgumentError, "unsupported schema version #{version}" unless version == schema_version

      parse_config(value)
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

    def self.parse_config(raw)
      return nil if raw.nil?
      raise SyrusYml::ParseError, "coworker_review: must be a mapping" unless raw.is_a?(Hash)

      enabled = ActiveModel::Type::Boolean.new.cast(raw.fetch("enabled", false)) || false
      rounds = Integer(raw.fetch("rounds", 1))
      valid_rounds = enabled ? rounds.between?(MIN_ROUNDS, MAX_ROUNDS) : rounds.between?(0, MAX_ROUNDS)
      unless valid_rounds
        raise SyrusYml::ParseError, "coworker_review.rounds: must be between #{MIN_ROUNDS} and #{MAX_ROUNDS}"
      end

      Config.new(
        enabled: enabled,
        rounds: rounds,
        criteria: parse_string_array(raw["criteria"], "coworker_review.criteria"),
        required: ActiveModel::Type::Boolean.new.cast(raw["required"]) || false
      )
    rescue ArgumentError, TypeError
      raise SyrusYml::ParseError, "coworker_review.rounds: must be an integer"
    end

    def self.parse_string_array(raw, label)
      return [] if raw.nil?
      raise SyrusYml::ParseError, "#{label}: must be an array of strings" unless raw.is_a?(Array)

      raw.each_with_index.map do |item, index|
        raise SyrusYml::ParseError, "#{label}[#{index}]: must be a string" unless item.is_a?(String)

        item.strip
      end.reject(&:empty?)
    end
    private_class_method :parse_config, :parse_string_array
  end
end
