module Admin
  module Plugins
    class Filter
      include Filters::BaseFilter

      def self.from_params(params, user: nil)
        q_tree = Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME])
        tree = q_tree || Filters::Ast.serialize(Filters::Ast::EMPTY)

        new(tree, user: user)
      end

      def initialize(tree, user: nil)
        @ast = Filters::Ast.parse(tree)
        @user = user
      end

      def apply(scope)
        Filters::Compiler.call(@ast, scope: scope, user: @user, subject: :admin_plugins)
      end
    end
  end
end
