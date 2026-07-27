module Filters
  # Shared behaviour mixed into all subject-specific Filter classes
  # (Jobs::Filter, Epics::Filter, Workflows::Filter, etc.).
  #
  # Each including class still owns:
  #   - `initialize` (signature varies per class)
  #   - `apply(scope)` (passes the right subject: to the compiler)
  #   - `build_tree_from_url_params` (subject-specific chip building)
  #   - any subject-specific predicate (pinned?, includes_archived_state?, …)
  module BaseFilter
    extend ActiveSupport::Concern

    # Build a Filter directly from an AST tree (hash shape). Used by
    # smart_folder_counts and by callers that already hold a tree.
    class_methods do
      def from_tree(tree, user: nil)
        new(tree, user: user)
      end

      private

      def chip(field, op, value)
        h = { "field" => field, "op" => op }
        h["value"] = value unless value.nil?
        h
      end

      # AND-merge two AST trees: { "and" => [...all children...] }.
      # Flattens one level so nested AND nodes don't accumulate when the
      # folder tree, q param, and URL params are all combined.
      def merge_and(left_tree, right_tree)
        children = [ left_tree, right_tree ].flat_map do |tree|
          if tree.is_a?(Hash) && tree["and"].is_a?(Array)
            tree["and"]
          else
            [ tree ]
          end
        end
        { "and" => children }
      end
    end

    # AST tree as a JSON-friendly Hash. Suitable for SmartFolder#filter
    # storage and for JSON-encoding into a hidden form field.
    def to_h
      Filters::Ast.serialize(@ast)
    end

    # base64-url-encoded JSON for embedding in the dashboard URL as
    # `?q=<encoded>` — the chip-bar UI's wire format.
    def to_query_param
      Filters::QueryParam.encode(to_h)
    end

    # True if the tree contains any chip.
    def active?
      chips.any?
    end

    private

    # Walk the AST and collect every Chip node anywhere in the tree.
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
