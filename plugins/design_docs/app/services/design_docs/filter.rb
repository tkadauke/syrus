module DesignDocs
  class Filter
    include Syrus::Host::Filters::BaseFilter

    def self.subject
      DesignDocs::SmartFolders::SUBJECT
    end

    def self.from_params(params, smart_folder: nil, user: nil)
      q_tree = Syrus::Host::Filters::QueryParam.decode(params[Syrus::Host::Filters::QueryParam::PARAM_NAME])
      folder_tree = smart_folder&.filter.presence
      url_tree = legacy_tree(params)

      tree = [ folder_tree, q_tree, url_tree ].compact.reduce { |acc, next_tree| merge_and(acc, next_tree) }
      tree ||= Syrus::Host::Filters::Ast.serialize(Syrus::Host::Filters::Ast::EMPTY)

      new(tree, user: user)
    end

    def self.from_tree(tree, user: nil)
      new(tree, user: user)
    end

    def self.legacy_tree(params)
      chips = []
      chips << chip("title", "contains", params[:search]) if params[:search].present?
      return nil if chips.empty?

      { "and" => chips }
    end

    def initialize(tree, user: nil)
      @ast = Syrus::Host::Filters::Ast.parse(tree.presence || { "and" => [] })
      @user = user
    end

    def apply(scope)
      Syrus::Host::Filters::Compiler.call(@ast, scope: scope, user: user, subject: self.class.subject)
    end

    private

    attr_reader :user
  end
end
