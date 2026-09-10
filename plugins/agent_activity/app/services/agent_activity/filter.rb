module AgentActivity
  # Parses the shared FilterBar query-tree (`?q=` base64-JSON) into an AST and
  # compiles it against the :agent_activity Filters subject. Unlike
  # WorkerTimeline::MacroQueryFilter, SessionsQuery's base relation is a single
  # AR relation (Run), so this can go straight through the normal
  # Filters::Compiler instead of hand-parsing a fixed field set.
  class Filter
    include Filters::BaseFilter

    def self.from_params(params, smart_folder: nil, user: nil)
      q_tree = Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME])
      folder_tree = smart_folder&.filter.presence

      tree = [ folder_tree, q_tree ].compact.reduce { |acc, next_tree| merge_and(acc, next_tree) }
      tree ||= Filters::Ast.serialize(Filters::Ast::EMPTY)

      new(tree, user: user)
    end

    def self.from_tree(tree, user: nil)
      new(tree, user: user)
    end

    def self.schema
      Filters::Schema.for(subject: :agent_activity)
    end

    def initialize(tree, user: nil)
      @ast = Filters::Ast.parse(tree)
      @user = user
    end

    def apply(scope)
      Filters::Compiler.call(@ast, scope: scope, user: @user, subject: :agent_activity)
    end

    def empty?
      @ast == Filters::Ast::EMPTY
    end
  end
end
