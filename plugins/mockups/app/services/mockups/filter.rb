module Mockups
  # Chip-bar filtering for the Mockups list, using the same AST/compiler path
  # as every other filtered list in the app.
  class Filter
    include Syrus::Host::Filters::BaseFilter

    def self.from_params(params, user: nil)
      tree = Syrus::Host::Filters::QueryParam.decode(params[Syrus::Host::Filters::QueryParam::PARAM_NAME]) ||
             Syrus::Host::Filters::Ast.serialize(Syrus::Host::Filters::Ast::EMPTY)

      new(tree, user: user)
    end

    def initialize(tree, user: nil)
      @ast = Syrus::Host::Filters::Ast.parse(tree)
      @user = user
    end

    # The chip bar renders from the applied tree, not from the query string.
    def as_tree
      Syrus::Host::Filters::Ast.serialize(@ast)
    end

    def apply(scope)
      Syrus::Host::Filters::Compiler.call(@ast, scope: scope, user: @user, subject: :mockup)
    end
  end
end
