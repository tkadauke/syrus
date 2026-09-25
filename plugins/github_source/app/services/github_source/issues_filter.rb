module GithubSource
  # Backs the repository Issues tab's FilterBar. Deliberately doesn't go
  # through Filters::Compiler/Registry --
  # GitHub issues are fetched from the GitHub API rather than queried out of
  # an ActiveRecord scope, so there's no predicate for a chip class to
  # compile against. Still speaks the same Filters::Ast/QueryParam wire
  # format FilterBar's frontend uses everywhere else, so the standard
  # chip-bar UI can drive it without any bespoke search form.
  class IssuesFilter
    SCHEMA = [
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
        "operators" => %w[ contains is ],
        "values" => []
      },
      {
        "field" => "label",
        "label" => "Label",
        "bucket" => "string",
        "operators" => %w[ contains is ],
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

      nil
    end

    def state
      value = values["state"].to_s
      %w[open closed].include?(value) ? value : nil
    end

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
  end
end
