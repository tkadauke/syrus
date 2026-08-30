module DesignDocs
  class Filter
    include Filters::BaseFilter

    def self.from_params(params, smart_folder: nil, user: nil)
      q_tree = Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME])
      folder_tree = smart_folder&.filter.presence
      tree = [ folder_tree, q_tree ].compact.reduce { |acc, next_tree| merge_and(acc, next_tree) }
      tree ||= Filters::Ast.serialize(Filters::Ast::EMPTY)

      new(tree, user: user)
    end

    def initialize(tree, user: nil)
      @ast = Filters::Ast.parse(tree)
      @user = user
    end

    def apply(scope)
      Filters::Compiler.call(@ast, scope: scope, user: @user, subject: DesignDocs::SmartFolders::SUBJECT)
    end
  end
end
