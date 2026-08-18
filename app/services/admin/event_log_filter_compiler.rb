module Admin
  class EventLogFilterCompiler
    def initialize(definition:)
      @definition = definition
    end

    def apply(scope, tree)
      compile(scope, Filters::Ast.parse(tree))
    end

    private

    attr_reader :definition

    def compile(scope, node)
      case node
      when Filters::Ast::AndNode
        node.children.reduce(scope) { |current, child| compile(current, child) }
      when Filters::Ast::OrNode
        compile_or(scope, node)
      when Filters::Ast::NotNode
        compile_not(scope, node)
      when Filters::Ast::Chip
        compile_chip(scope, node)
      else
        raise ArgumentError, "unknown filter node: #{node.class}"
      end
    end

    def compile_or(scope, node)
      return scope if node.children.empty?

      primary_key = scope.model.primary_key or raise ArgumentError, "#{scope.model.name} has no primary key"
      primary_key_column = scope.arel_table[primary_key]
      predicates = node.children.map do |child|
        child_scope = compile(scope, child)
        primary_key_column.in(child_scope.except(:select, :order).select(primary_key).arel)
      end
      scope.where(predicates.reduce { |left, right| left.or(right) })
    end

    def compile_not(scope, node)
      primary_key = scope.model.primary_key or raise ArgumentError, "#{scope.model.name} has no primary key"
      child_scope = compile(scope, node.child)
      scope.where(scope.arel_table[primary_key].not_in(child_scope.except(:select, :order).select(primary_key).arel))
    end

    def compile_chip(scope, node)
      field = definition.fields[node.field]
      return scope unless field
      return scope unless field.operators.map(&:to_s).include?(node.op.to_s)

      field.apply(scope, node.op, node.value)
    end
  end
end
