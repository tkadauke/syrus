module Jobs
  # Thin wrapper over Filters::Ast + Filters::Compiler that keeps the
  # existing public interface (`#apply`, `#active?`, `#pinned?`,
  # `#to_h`) so callers don't need to know about the AST shape. The
  # bulk of filter logic lives in Filters::Chips now; this class
  # exists to bridge the controller's flat URL params + an optional
  # active SmartFolder into a single AST tree.
  class Filter
    include Filters::BaseFilter

    # Flat URL-param keys the legacy dropdown filter bar still emits.
    # Each is translated to one or more AST chips by `from_params`.
    LEGACY_URL_KEYS = %w[ state repository_id kind pr age attention tag_ids ].freeze

    # Build a Filter from the controller's request params plus an
    # optional active SmartFolder. Source-of-truth precedence (when
    # multiple inputs are present, they AND together with the
    # smart folder as the floor):
    #
    #   1. `q=<base64-json>` — chip-bar UI's canonical wire format.
    #      A full AST tree, possibly with OR / NOT.
    #   2. Legacy flat URL params (state=, repository_id=, etc.) —
    #      still emitted by the existing dropdown form. Translated
    #      to a flat AND-of-chips tree via build_tree_from_url_params.
    #   3. SmartFolder#filter — the floor when one is active.
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
      Filters::Compiler.call(@ast, scope: scope, user: @user, subject: :job)
    end

    # True if the tree contains an `attention: pinned` chip anywhere.
    # The controller uses this to order results by pin timestamp.
    def pinned?
      chips.any? { |chip| chip.field == "attention" && chip.value.to_s == "pinned" }
    end

    private

    # ---- URL-param → AST tree adapter ----

    def self.build_tree_from_url_params(params)
      # Accept either a regular Hash (specs) or ActionController::Parameters
      # (controller). Permit only the legacy URL keys so we don't trip
      # `unable to convert unpermitted parameters to hash`.
      params =
        if params.respond_to?(:permit)
          params.permit(*LEGACY_URL_KEYS, tag_ids: []).to_h
        else
          params.to_h
        end
      params = params.transform_keys(&:to_s)

      chips = []

      if (attention = params["attention"]).is_a?(String) && attention.present?
        chips << chip("attention", "is", attention)
      end

      # state=open/closed is a direct state filter; state=failed/succeeded
      # is sugar for "open AND latest_workflow_state matches" — same
      # semantics today's dropdown emits.
      case params["state"]
      when "open", "closed"
        chips << chip("state", "is", params["state"])
      when "failed", "succeeded"
        chips << chip("state", "is", "open")
        chips << chip("latest_workflow_state", "is", params["state"])
      end

      if (repository_id = params["repository_id"]).present?
        chips << chip("repository_id", "is", repository_id)
      end

      if (kind = params["kind"]).present? && Job::KINDS.include?(kind)
        chips << chip("kind", "is", kind)
      end

      case params["pr"]
      when "has_pr" then chips << chip("pr_present", "is", "has")
      when "no_pr"  then chips << chip("pr_present", "is", "none")
      end

      if (age = params["age"]).present?
        chips << chip("age", "is", age)
      end

      ids = Array(params["tag_ids"]).flatten.compact_blank.map(&:to_s)
      chips << chip("tags", "contains_any", ids) if ids.any?

      return nil if chips.empty?

      { "and" => chips }
    end
    private_class_method :build_tree_from_url_params
  end
end
