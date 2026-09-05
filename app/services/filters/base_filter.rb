module Filters
  # Shared behaviour mixed into all subject-specific Filter classes
  # (Jobs::Filter, Epics::Filter, Workflows::Filter, etc.).
  #
  # `initialize` and `from_params` are template methods hoisted here for
  # classes with the standard `(tree, user: nil)` / `(params, smart_folder:,
  # user:)` signatures. Each including class still owns:
  #   - `apply(scope)` (passes the right subject: to the compiler)
  #   - `build_tree_from_url_params` (subject-specific chip building — the
  #     hook `from_params` calls into)
  #   - any subject-specific predicate (pinned?, includes_archived_state?, …)
  #
  # Filter classes with a different `initialize`/`from_params` signature
  # (e.g. Admin::Queue::Filter's required `tab:`) define their own directly,
  # which takes precedence over these template methods.
  module BaseFilter
    extend ActiveSupport::Concern

    # Build a Filter directly from an AST tree (hash shape). Used by
    # smart_folder_counts and by callers that already hold a tree.
    class_methods do
      def from_tree(tree, user: nil)
        new(tree, user: user)
      end

      # Build a Filter from the controller's request params plus an
      # optional active SmartFolder. Source-of-truth precedence (when
      # multiple inputs are present, they AND together with the
      # smart folder as the floor):
      #
      #   1. `q=<base64-json>` — chip-bar UI's canonical wire format.
      #      A full AST tree, possibly with OR / NOT.
      #   2. Legacy flat URL params (state=, repository_id=, etc.) —
      #      still emitted by the existing dropdown form. Translated
      #      to a flat AND-of-chips tree via build_tree_from_url_params,
      #      a subject-specific hook each including class must define.
      #   3. SmartFolder#filter — the floor when one is active.
      def from_params(params, smart_folder: nil, user: nil)
        q_tree = Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME])
        url_tree = build_tree_from_url_params(params)
        folder_tree = smart_folder&.filter.presence

        tree = [ folder_tree, q_tree, url_tree ].compact.reduce { |acc, next_tree| merge_and(acc, next_tree) }
        tree ||= Filters::Ast.serialize(Filters::Ast::EMPTY)

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

    def initialize(tree, user: nil)
      @ast = Filters::Ast.parse(tree)
      @user = user
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
