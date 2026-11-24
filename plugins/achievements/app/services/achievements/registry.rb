module Achievements
  # Stable registry of achievement definitions, validated as a whole.
  #
  # `problems` never raises: a bad definition set is reported (boot log, plugin
  # health) rather than stopping the instance. `validate!` is for tests and for
  # callers that must refuse to proceed.
  class Registry
    class InvalidRegistry < StandardError
      attr_reader :problems

      def initialize(problems)
        @problems = problems
        super("Invalid achievement definitions: #{problems.join('; ')}")
      end
    end

    SCOPES = %i[instance user].freeze
    SUBJECT_KINDS = %i[job epic repository workflow user installation].freeze
    # Which subject kinds each scope may point at: an instance milestone is not
    # about one person, and a per-user accomplishment is not about the installation.
    SCOPE_FORBIDDEN_SUBJECTS = { instance: %i[user], user: %i[installation] }.freeze
    VISIBILITIES = %i[visible hidden].freeze
    CATEGORIES = %i[work review landing collaboration milestone].freeze
    RARITIES = %i[common uncommon rare epic legendary].freeze
    KEY_FORMAT = /\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*\z/
    IDENTITY_FORMAT = /\A[A-Za-z][A-Za-z0-9_.:]*\z/
    PRESENTATION_KEYS = %w[title_key description_key glyph teaser_key].freeze
    MAX_PRESENTATION_VALUE = 200

    attr_reader :definitions

    def self.default
      @default = nil if Rails.env.development?
      @default ||= new(Achievements::Catalog.definitions)
    end

    def self.reset_default! = @default = nil

    def initialize(definitions)
      @definitions = definitions.to_a.freeze
    end

    def fetch(key) = find(key) || raise(KeyError, "unknown achievement definition: #{key}")

    def find(key)
      key = key.to_s
      definitions.find { |definition| definition.key == key }
    end

    def keys = definitions.map(&:key)

    def for_scope(scope) = definitions.select { |definition| definition.scope == scope.to_sym }

    def valid? = problems.empty?

    def validate!
      found = problems
      raise InvalidRegistry, found if found.any?

      self
    end

    def problems
      duplicate_problems + definitions.flat_map { |definition| definition_problems(definition) }
    end

    private

    def duplicate_problems
      keys.tally.select { |_key, count| count > 1 }.keys.map { |key| "#{key}: duplicate key" }
    end

    def definition_problems(definition)
      label = definition.key.presence || "(blank key)"
      issues = []
      issues << "key must be lowercase dotted snake_case" unless definition.key.match?(KEY_FORMAT)
      issues << "version must be a positive integer" unless definition.version.is_a?(Integer) && definition.version.positive?
      issues << "scope must be one of #{SCOPES.join(', ')}" unless SCOPES.include?(definition.scope)
      issues << "trigger must be a domain-event identity" unless definition.trigger.match?(IDENTITY_FORMAT)
      issues << "evaluator must be an evaluator identity" unless definition.evaluator.match?(IDENTITY_FORMAT)
      issues << "visibility must be one of #{VISIBILITIES.join(', ')}" unless VISIBILITIES.include?(definition.visibility)
      issues << "category must be one of #{CATEGORIES.join(', ')}" unless CATEGORIES.include?(definition.category)
      issues << "rarity must be one of #{RARITIES.join(', ')}" unless RARITIES.include?(definition.rarity)
      issues.concat(subject_problems(definition))
      issues.concat(presentation_problems(definition))
      issues.map { |issue| "#{label}: #{issue}" }
    end

    def subject_problems(definition)
      kinds = definition.subject_kinds
      return [ "subject_kinds must not be empty" ] if kinds.empty?

      issues = []
      unknown = kinds - SUBJECT_KINDS
      issues << "unknown subject kinds #{unknown.join(', ')}" if unknown.any?
      issues << "duplicate subject kinds" if kinds.uniq.size != kinds.size
      conflicting = kinds & SCOPE_FORBIDDEN_SUBJECTS.fetch(definition.scope, [])
      issues << "#{definition.scope} scope cannot use subject kind #{conflicting.join(', ')}" if conflicting.any?
      issues
    end

    def presentation_problems(definition)
      fixture = definition.presentation
      return [ "presentation must be a hash" ] unless fixture.is_a?(Hash)

      issues = []
      unknown = fixture.keys - PRESENTATION_KEYS
      issues << "unknown presentation keys #{unknown.join(', ')}" if unknown.any?
      too_long = fixture.select { |_k, v| !v.is_a?(String) || v.length > MAX_PRESENTATION_VALUE }.keys
      issues << "presentation values must be strings up to #{MAX_PRESENTATION_VALUE} characters (#{too_long.join(', ')})" if too_long.any?
      # A hidden achievement must not leak what it is before it unlocks.
      issues << "hidden achievements cannot carry a teaser_key" if definition.hidden? && fixture.key?("teaser_key")
      issues
    end
  end
end
