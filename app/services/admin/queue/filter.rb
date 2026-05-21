module Admin
  module Queue
    class Filter
      def self.from_params(params, smart_folder: nil, user: nil, tab:)
        q_tree = Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME])
        folder_tree = smart_folder&.filter.presence

        tree = [ folder_tree, q_tree ].compact.reduce { |acc, next_tree| merge_and(acc, next_tree) }
        tree ||= default_tree(tab)
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
        Filters::Compiler.call(@ast, scope: scope, user: @user, subject: :admin_queue)
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

      def self.default_tree(tab)
        return nil unless tab.to_sym == :failed

        {
          "and" => [
            { "field" => "failed_since", "op" => "within_last", "value" => { "n" => 1, "unit" => "days" } }
          ]
        }
      end

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

      private

      def chips
        collected = []
        walk = ->(node) {
          case node
          when Filters::Ast::Chip then collected << node
          when Filters::Ast::AndNode, Filters::Ast::OrNode
            node.children.each(&walk)
          when Filters::Ast::NotNode
            walk.call(node.child)
          end
        }
        walk.call(@ast)
        collected
      end
    end
  end
end
