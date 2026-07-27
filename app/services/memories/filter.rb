module Memories
  class Filter
    include Filters::BaseFilter

    LEGACY_URL_KEYS = %w[ scope kind published q search repository_id ].freeze

    def self.from_params(params, user:)
      new(build_tree_from_params(params), user: user)
    end

    def initialize(tree, user: nil)
      @ast = Filters::Ast.parse(tree || Filters::Ast.serialize(Filters::Ast::EMPTY))
      @user = user
    end

    def apply(scope)
      Filters::Compiler.call(@ast, scope: scope, user: @user, subject: :memory)
    end

    def self.build_tree_from_params(params)
      q_tree = Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME])
      legacy_tree = build_tree_from_url_params(params, q_is_filter: q_tree.present?)
      [ q_tree, legacy_tree ].compact.reduce { |acc, next_tree| merge_and(acc, next_tree) } ||
        Filters::Ast.serialize(Filters::Ast::EMPTY)
    end
    private_class_method :build_tree_from_params

    def self.build_tree_from_url_params(params, q_is_filter:)
      params =
        if params.respond_to?(:permit)
          params.permit(*LEGACY_URL_KEYS).to_h
        else
          params.to_h
        end
      params = params.transform_keys(&:to_s)
      chips = []

      if (scope = params["scope"]).present? && ChatMemory::SCOPE.include?(scope)
        chips << chip("scope", "is", scope)
      end

      if (kind = params["kind"]).present? && ChatMemory::KIND.include?(kind)
        chips << chip("kind", "is", kind)
      end

      case params["published"]
      when "true", "1", true
        chips << chip("published", "is_true", nil)
      when "false", "0", false
        chips << chip("published", "is_false", nil)
      end

      if (repository_id = params["repository_id"]).present?
        chips << chip("repository_id", "is", repository_id)
      end

      query = params["search"].presence || (q_is_filter ? nil : params["q"].presence)
      chips << chip("content", "contains", query.to_s.strip) if query.to_s.strip.present?

      return nil if chips.empty?

      { "and" => chips }
    end
    private_class_method :build_tree_from_url_params
  end
end
