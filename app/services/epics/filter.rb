module Epics
  # Epic-side wrapper over Filters::Ast + Filters::Compiler. It mirrors
  # Jobs::Filter's public interface while keeping Epic-specific legacy
  # URL-param translation intentionally small.
  class Filter
    include Filters::BaseFilter

    LEGACY_URL_KEYS = %w[ state repository_id attention ].freeze

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
      Filters::Compiler.call(@ast, scope: scope, user: @user, subject: :epic)
    end

    def pinned?
      chips.any? { |chip| chip.field == "attention" && chip.value.to_s == "pinned" }
    end

    def includes_archived_state?
      chips.any? { |chip| chip.field == "state" && chip.value.to_s == "archived" }
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
  end
end
