module AgentActivity
  # Parses the shared FilterBar query-tree (`?q=` base64-JSON) into an AST and
  # compiles it against the :agent_activity Filters subject. Unlike
  # WorkerTimeline::MacroQueryFilter, SessionsQuery's base relation is a single
  # AR relation (Run), so this can go straight through the normal
  # Filters::Compiler instead of hand-parsing a fixed field set.
  class Filter
    include Filters::BaseFilter

    def self.from_params(params, user: nil)
      new(Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME]), user: user)
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
  end
end
