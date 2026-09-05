module Mockups
  # Chip-bar filtering for the Mockups list, using the same AST/compiler path
  # as every other filtered list in the app.
  class Filter
    include Filters::BaseFilter

    def self.from_params(params, user: nil)
      tree = Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME]) ||
             Filters::Ast.serialize(Filters::Ast::EMPTY)

      new(tree, user: user)
    end

    def initialize(tree, user: nil)
      @ast = Filters::Ast.parse(tree)
      @user = user
    end

    # The chip bar renders from the applied tree, not from the query string.
    def as_tree
      Filters::Ast.serialize(@ast)
    end

    def apply(scope)
      Filters::Compiler.call(@ast, scope: scope, user: @user, subject: :mockup)
    end
  end
end
