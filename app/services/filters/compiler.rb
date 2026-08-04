module Filters
  # AST → ActiveRecord scope. Walks an Ast::AndNode / OrNode / NotNode
  # / Chip tree and applies it to a base scope. `user:` is passed
  # through to chips that need operator-context (e.g. the pinned
  # attention preset joins job_pins for the current user).
  class Compiler
    def self.call(node, scope:, user: nil, subject: :job)
      new(scope: scope, user: user, subject: subject).compile(node)
    end

    def initialize(scope:, user: nil, subject: :job)
      @scope = scope
      @user = user
      @subject = Filters.subject_for(subject)
    end

    def compile(node)
      case node
      when Ast::AndNode then compile_and(node)
      when Ast::OrNode  then compile_or(node)
      when Ast::NotNode then compile_not(node)
      when Ast::Chip    then compile_chip(node)
      else
        raise ArgumentError, "unknown AST node: #{node.class}"
      end
    end

    private

    def compile_and(node)
      node.children.reduce(@scope) do |scope, child|
        self.class.new(scope: scope, user: @user, subject: @subject.name).compile(child)
      end
    end

    def compile_or(node)
      return @scope if node.children.empty?

      primary_key = primary_key_attribute
      predicates = node.children.map do |child|
        child_scope = self.class.new(scope: @scope, user: @user, subject: @subject.name).compile(child)
        primary_key_column.in(primary_key_subquery(child_scope, primary_key))
      end

      @scope.where(predicates.reduce { |left, right| left.or(right) })
    end

    def compile_not(node)
      primary_key = primary_key_attribute
      child_scope = self.class.new(scope: @scope, user: @user, subject: @subject.name).compile(node.child)

      @scope.where(primary_key_column.not_in(primary_key_subquery(child_scope, primary_key)))
    end

    def compile_chip(node)
      chip_class = @subject.find_chip(node.field)
      chip_class.new(scope: @scope, op: node.op, value: node.value, user: @user).apply
    end

    def primary_key_attribute
      @scope.model.primary_key or raise ArgumentError, "#{@scope.model.name} has no primary key"
    end

    def primary_key_column
      @scope.arel_table[primary_key_attribute]
    end

    def primary_key_subquery(scope, primary_key)
      scope.except(:select, :order).select(primary_key).arel
    end
  end
end
