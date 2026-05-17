module Epics
  class Filter
    LEGACY_URL_KEYS = %w[ state repository_id attention ].freeze

    def self.from_params(params, smart_folder: nil, user: nil)
      q_tree = Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME])
      url_tree = build_tree_from_url_params(params)
      folder_tree = smart_folder&.filter.presence

      tree = [ folder_tree, q_tree, url_tree ].compact.reduce { |acc, next_tree| merge_and(acc, next_tree) }
      tree ||= Filters::Ast.serialize(Filters::Ast::EMPTY)

      new(tree, user: user)
    end

    def self.from_tree(tree, user: nil)
      new(tree, user: user)
    end

    def initialize(tree, user: nil)
      @ast = Filters::Ast.parse(tree)
      @user = user
    end

    def apply(scope)
      Filters::Compiler.call(@ast, scope: scope, user: @user, subject: :epic)
    end

    def active?
      chips.any?
    end

    def to_h
      Filters::Ast.serialize(@ast)
    end

    def to_query_param
      Filters::QueryParam.encode(to_h)
    end

    private

    def chips
      collected = []
      walk = ->(node) {
        case node
        when Filters::Ast::Chip
          collected << node
        when Filters::Ast::AndNode, Filters::Ast::OrNode
          node.children.each(&walk)
        when Filters::Ast::NotNode
          walk.call(node.child)
        end
      }
      walk.call(@ast)
      collected
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
      chips << chip("attention", "is", params["attention"]) if params["attention"].present?
      chips << chip("state", "is", params["state"]) if Epic::STATES.include?(params["state"])
      chips << chip("repository_id", "is", params["repository_id"]) if params["repository_id"].present?

      return nil if chips.empty?

      { "and" => chips }
    end
    private_class_method :build_tree_from_url_params

    def self.chip(field, op, value)
      { "field" => field, "op" => op, "value" => value }
    end
    private_class_method :chip

    def self.merge_and(left_tree, right_tree)
      children = [ left_tree, right_tree ].flat_map do |tree|
        if tree.is_a?(Hash) && tree["and"].is_a?(Array)
          tree["and"]
        else
          [ tree ]
        end
      end
      { "and" => children }
    end
    private_class_method :merge_and
  end
end
