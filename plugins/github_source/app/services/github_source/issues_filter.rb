module GithubSource
  # Backs the repository Issues tab's FilterBar. Deliberately doesn't go
  # through Filters::Compiler/Registry --
  # GitHub issues are fetched from the GitHub API rather than queried out of
  # an ActiveRecord scope, so there's no predicate for a chip class to
  # compile against. Still speaks the same Filters::Ast/QueryParam wire
  # format FilterBar's frontend uses everywhere else, so the standard
  # chip-bar UI can drive it without any bespoke search form.
  class IssuesFilter
    PRESET_FIELD = "preset"
    PRESETS = {
      "inbox" => { "state" => "open", "delegated" => false },
      "delegated" => { "state" => "open", "delegated" => true },
      "open" => { "state" => "open" },
      "closed" => { "state" => "closed" }
    }.freeze
    SCHEMA = [
      {
        "field" => PRESET_FIELD,
        "label" => "Preset",
        "bucket" => "preset",
        "operators" => %w[ is ],
        "values" => PRESETS.keys.map { |value| { "value" => value, "label" => value.capitalize } }
      },
      {
        "field" => "query",
        "label" => "Search",
        "bucket" => "string",
        "operators" => %w[ contains ],
        "values" => [],
        "free_text_search" => true
      },
      {
        "field" => "author",
        "label" => "Author",
        "bucket" => "string",
        "operators" => %w[ contains ],
        "values" => []
      },
      {
        "field" => "label",
        "label" => "Label",
        "bucket" => "string",
        "operators" => %w[ contains ],
        "values" => []
      },
      {
        "field" => "delegated",
        "label" => "Delegated",
        "bucket" => "enum",
        "operators" => %w[ is ],
        "values" => [
          { "value" => "true", "label" => "Delegated" },
          { "value" => "false", "label" => "Not delegated" }
        ]
      },
      {
        "field" => "state",
        "label" => "State",
        "bucket" => "enum",
        "operators" => %w[ is ],
        "values" => [
          { "value" => "open", "label" => "Open" },
          { "value" => "closed", "label" => "Closed" }
        ]
      }
    ].freeze
    OWNED_FIELDS = SCHEMA.map { |field| field.fetch("field") }.freeze

    def self.schema
      SCHEMA
    end

    def self.from_params(params)
      new(Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME]))
    end

    def self.for_request(params, folder:)
      return from_params(params) if params.key?(Filters::QueryParam::PARAM_NAME) || params.key?(Filters::QueryParam::PARAM_NAME.to_s)
      return new({ "and" => [] }) unless PRESETS.key?(folder)

      new({ "and" => [ { "field" => PRESET_FIELD, "op" => "is", "value" => folder } ] })
    end

    def initialize(tree)
      @ast = Filters::Ast.parse(tree)
    end

    def to_h
      Filters::Ast.serialize(@ast)
    end

    def query
      values["query"].presence
    end

    def author
      values["author"].presence
    end

    def label
      values["label"].presence
    end

    def delegated
      value = values["delegated"]
      return true if value.to_s == "true"
      return false if value.to_s == "false"

      preset_constraints["delegated"]
    end

    def state
      value = values["state"].to_s
      return value if %w[open closed].include?(value)

      preset_constraints["state"]
    end

    def preset = values[PRESET_FIELD].presence_in(PRESETS.keys)

    private

    def values
      @values ||= begin
        collected = {}
        collect = lambda do |node|
          case node
          when Filters::Ast::Chip
            collected[node.field] = node.value if OWNED_FIELDS.include?(node.field) && !collected.key?(node.field)
          when Filters::Ast::AndNode, Filters::Ast::OrNode
            node.children.each(&collect)
          when Filters::Ast::NotNode
            collect.call(node.child)
          end
        end
        collect.call(@ast)
        collected
      end
    end

    def preset_constraints
      PRESETS.fetch(preset, {})
    end
  end
end
