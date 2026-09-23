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

      # Whether `smart_folder`'s saved filter should still act as the floor
      # for a `from_params` call built from these params. `from_params`
      # itself always ANDs a given `smart_folder:` argument in (see its own
      # spec coverage), so any caller backing a chip-bar UI with an active
      # SmartFolder must resolve its `smart_folder:` argument through here
      # instead of passing the currently selected folder unconditionally —
      # otherwise every add/edit/remove in the chip bar re-ANDs the folder's
      # saved filter back into the user's own ad hoc one: duplicating added
      # chips, resurrecting edited-away values, and reinstating removed
      # ones. Mirrors App::DashboardPayload#active_smart_folder_for_filter.
      #
      # A present `q=` — even one that decodes to zero chips — always means
      # the chip bar itself is now the source of truth: FilterBar sends an
      # explicit empty tree once a SmartFolder is selected specifically so
      # "the chip bar was just emptied" can be told apart from "the chip bar
      # was never touched" (both of which leave the tree empty, but only the
      # former should drop the folder's floor). Absent a `q=` at all, fall
      # back to whether the legacy flat URL params carry any chips.
      def smart_folder_floor(params, smart_folder, user: nil)
        return nil if smart_folder.nil?
        return nil if params.key?(Filters::QueryParam::PARAM_NAME) || params.key?(Filters::QueryParam::PARAM_NAME.to_s)

        from_params(params, smart_folder: nil, user: user).active? ? nil : smart_folder
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

    # Bounded-cost row count: stops scanning at limit + 1 rows regardless of
    # true match count, capped at limit. Mirrors the pattern
    # AgentActivity::SessionsQuery used privately before this primitive
    # existed. `Filters::BaseFilter.capped_count` is the module-level
    # implementation other query objects (that don't include this module)
    # can delegate to directly.
    def self.capped_count(scope, limit: SmartFolder::COUNT_CAP)
      count = scope.reselect(:id).limit(limit + 1).pluck(:id).size
      [ count, limit ].min
    end

    def capped_count(scope, limit: SmartFolder::COUNT_CAP)
      Filters::BaseFilter.capped_count(scope, limit: limit)
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
