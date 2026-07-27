module Workflows
  # Workflow-side wrapper over Filters::Ast + Filters::Compiler. Mirrors
  # Jobs::Filter / Epics::Filter so controllers and SmartFolders can pass
  # either the chip-bar q param, legacy flat params, or a stored AST tree.
  class Filter
    include Filters::BaseFilter

    LEGACY_URL_KEYS = %w[ state trigger_kind job_id ].freeze

    def self.from_params(params, smart_folder: nil, user: nil)
      q_tree = Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME])
      url_tree = build_tree_from_url_params(params)
      folder_tree = smart_folder&.filter.presence

      tree = [ folder_tree, q_tree, url_tree ].compact.reduce { |acc, next_tree| merge_and(acc, next_tree) }
      tree ||= Filters::Ast.serialize(Filters::Ast::EMPTY)

      new(tree, user: user)
    end

    def initialize(tree, user: nil)
      @ast = Filters::Ast.parse(tree)
      @user = user
    end

    def apply(scope)
      Filters::Compiler.call(@ast, scope: scope, user: @user, subject: :workflow)
    end

    def default?
      to_h == Filters::Ast.serialize(Filters::Ast::EMPTY)
    end

    def pinned?
      false
    end

    def self.build_tree_from_url_params(params)
      params =
        if params.respond_to?(:permit)
          params.permit(*LEGACY_URL_KEYS).to_h
        else
          params.to_h
        end
      params = params.transform_keys(&:to_s)

      chips = []
      chips << chip("state", "is", params["state"]) if workflow_states.include?(params["state"])
      chips << chip("trigger_kind", "is", params["trigger_kind"]) if workflow_trigger_kinds.include?(params["trigger_kind"])
      chips << chip("job_id", "is", params["job_id"]) if params["job_id"].present?

      return nil if chips.empty?

      { "and" => chips }
    end
    private_class_method :build_tree_from_url_params

    def self.workflow_states
      Filters::Chips::Workflows::State.values
    end
    private_class_method :workflow_states

    def self.workflow_trigger_kinds
      Filters::Chips::Workflows::TriggerKind.values
    end
    private_class_method :workflow_trigger_kinds
  end
end
