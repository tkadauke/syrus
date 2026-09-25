module TestInsights
  # Backs the repository Tests tab's FilterBar: a free-text "query" field,
  # test metadata fields, and a single-select "reason" field (failing/flaky/slow). Deliberately doesn't
  # go through Filters::Compiler/Registry -- both fields resolve to
  # TestInsights::Query keyword args (query:, category:) rather than an
  # ActiveRecord predicate to compile, so there's no scope-building chip
  # class to register. Still speaks the same Filters::Ast/QueryParam wire
  # format FilterBar's frontend uses everywhere else.
  class TestsFilter
    FIELDS = %w[ query reason status suite_name file_path ].freeze

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
        "field" => "reason",
        "label" => "Reason",
        "bucket" => "enum",
        "operators" => %w[ is ],
        "values" => %w[ failing flaky slow ].map { |value| { "value" => value, "label" => Filters::Schema.humanize_value(value) } }
      },
      {
        "field" => "status",
        "label" => "Status",
        "bucket" => "enum",
        "operators" => %w[ is ],
        "values" => %w[ passed failed error skipped ].map { |value| { "value" => value, "label" => Filters::Schema.humanize_value(value) } }
      },
      {
        "field" => "suite_name",
        "label" => "Suite",
        "bucket" => "string",
        "operators" => %w[ contains ],
        "values" => []
      },
      {
        "field" => "file_path",
        "label" => "File path",
        "bucket" => "string",
        "operators" => %w[ contains ],
        "values" => []
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

    def active?
      values.values.any?(&:present?)
    end

    def query
      values["query"].presence
    end

    def reason
      values["reason"].presence
    end

    def query_filters
      values.slice("status", "suite_name", "file_path").transform_keys(&:to_sym).compact_blank
    end

    private

    def values
      @values ||= begin
        collected = {}
        collect = lambda do |node|
          case node
          when Filters::Ast::Chip
            collected[node.field] = node.value if FIELDS.include?(node.field) && !collected.key?(node.field)
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
