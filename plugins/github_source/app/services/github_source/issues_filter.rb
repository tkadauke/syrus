module GithubSource
  # Backs the repository Issues tab's FilterBar: a single free-text "query"
  # field. Deliberately doesn't go through Filters::Compiler/Registry --
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
      }
    ].freeze

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

    private

    def values
      @values ||= begin
        collected = {}
        collect = lambda do |node|
          case node
          when Filters::Ast::Chip
            collected[node.field] = node.value if node.field == "query" && !collected.key?(node.field)
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
