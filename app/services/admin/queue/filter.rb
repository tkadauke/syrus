module Admin
  module Queue
    class Filter
      include Filters::BaseFilter

      def self.from_params(params, smart_folder: nil, user: nil, tab:)
        q_tree = Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME])
        url_tree = build_tree_from_url_params(params, tab: tab)
        folder_tree = smart_folder&.filter.presence

        tree = [ folder_tree, q_tree, url_tree ].compact.reduce { |acc, next_tree| merge_and(acc, next_tree) }
        tree ||= default_tree(tab)
        tree ||= Filters::Ast.serialize(Filters::Ast::EMPTY)

        new(tree, user: user)
      end

      def initialize(tree, user: nil)
        @ast = Filters::Ast.parse(tree)
        @user = user
      end

      def apply(scope)
        Filters::Compiler.call(@ast, scope: scope, user: @user, subject: :admin_queue)
      end

      def self.default_tree(tab)
        return nil unless tab.to_sym == :failed

        {
          "and" => [
            { "field" => "failed_since", "op" => "within_last", "value" => { "n" => 1, "unit" => "days" } }
          ]
        }
      end

      def self.build_tree_from_url_params(params, tab:)
        return nil unless tab.to_sym == :failed

        since = params[:since].presence || params["since"].presence
        return nil if since.blank?

        {
          "and" => [
            { "field" => "failed_since", "op" => "after", "value" => Time.iso8601(since.to_s).iso8601 }
          ]
        }
      end
    end
  end
end
