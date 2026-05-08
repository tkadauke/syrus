module Admin
  # Translates the `?gh_rate=`, `?admin=`, `?email=`,
  # `?has_github_token=`, `?has_claude_token=`, `?has_codex_token=`
  # query params from the
  # admin user directory into an ActiveRecord scope. Shared by the
  # HTML and JSON admin user controllers.
  #
  # `gh_rate` levels mirror the overview tile's classification —
  # "low" means below 10% of cap, the same threshold the tile flags
  # as a warning. "exhausted" is 0 remaining.
  class UsersFilter
    GH_RATE_LOW_THRESHOLD = 0.10

    # Stable order: known filters → labelled values for the
    # filter UI strip. The query-param keys are also the filter
    # names; values that aren't in this list are ignored.
    BOOLEAN_KEYS = %w[ admin has_github_token has_claude_token has_codex_token ].freeze
    VALID_GH_RATE = %w[ low exhausted ].freeze

    attr_reader :params

    def initialize(params)
      @params = params || {}
    end

    def scope
      relation = User.all
      relation = filter_email(relation)
      relation = filter_admin(relation)
      relation = filter_has_github_token(relation)
      relation = filter_has_claude_token(relation)
      relation = filter_has_codex_token(relation)
      relation = filter_gh_rate(relation)
      relation
    end

    # The set of active filters as `{ key => display_value }`, for
    # rendering "current filters" pills in the UI.
    def active_filters
      filters = {}
      filters["email"]            = email             if email.present?
      filters["admin"]            = boolean_repr(:admin)            unless admin_param.nil?
      filters["has_github_token"] = boolean_repr(:has_github_token) unless has_github_token_param.nil?
      filters["has_claude_token"] = boolean_repr(:has_claude_token) unless has_claude_token_param.nil?
      filters["has_codex_token"]  = boolean_repr(:has_codex_token)  unless has_codex_token_param.nil?
      filters["gh_rate"]          = gh_rate           if gh_rate_filter
      filters
    end

    def any?
      active_filters.any?
    end

    private

    def email
      params[:email].to_s.strip
    end

    def admin_param;            normalize_bool(params[:admin]);            end
    def has_github_token_param; normalize_bool(params[:has_github_token]); end
    def has_claude_token_param; normalize_bool(params[:has_claude_token]); end
    def has_codex_token_param;  normalize_bool(params[:has_codex_token]);  end

    def gh_rate
      params[:gh_rate].to_s.downcase
    end

    def gh_rate_filter
      VALID_GH_RATE.include?(gh_rate) ? gh_rate : nil
    end

    def filter_email(relation)
      return relation if email.blank?
      relation.where("email_address LIKE ?", "%#{email}%")
    end

    def filter_admin(relation)
      return relation if admin_param.nil?
      relation.where(admin: admin_param)
    end

    # `encrypts :github_token` makes the column ciphertext; it's
    # NULL when no token is set, non-NULL when set. We can't filter
    # on the plaintext value but presence is enough.
    def filter_has_github_token(relation)
      return relation if has_github_token_param.nil?
      has_github_token_param ? relation.where.not(github_token: nil)
                             : relation.where(github_token: nil)
    end

    def filter_has_claude_token(relation)
      return relation if has_claude_token_param.nil?
      has_claude_token_param ? relation.where.not(claude_oauth_token: nil)
                             : relation.where(claude_oauth_token: nil)
    end

    def filter_has_codex_token(relation)
      return relation if has_codex_token_param.nil?
      has_codex_token_param ? relation.where("codex_api_key IS NOT NULL OR codex_auth_json IS NOT NULL")
                            : relation.where(codex_api_key: nil, codex_auth_json: nil)
    end

    # 10%-of-cap threshold matches the "GitHub rate limits" tile on
    # /admin so a click on that tile lands on the same set the tile
    # was counting. "exhausted" = literal zero remaining.
    def filter_gh_rate(relation)
      case gh_rate_filter
      when "low"
        relation.where("gh_rate_limit_remaining IS NOT NULL AND gh_rate_limit_limit > 0 AND gh_rate_limit_remaining < gh_rate_limit_limit * ?", GH_RATE_LOW_THRESHOLD)
      when "exhausted"
        relation.where(gh_rate_limit_remaining: 0)
      else
        relation
      end
    end

    # Tri-state: nil = "filter not provided", true/false = filter on.
    # We accept the canonical truthy/falsy strings and ignore garbage
    # rather than raising — keeps URLs robust for typos.
    def normalize_bool(value)
      return nil if value.nil?
      case value.to_s.downcase
      when "true", "1", "yes"  then true
      when "false", "0", "no"  then false
      end
    end

    def boolean_repr(filter_key)
      param = case filter_key
      when :admin            then admin_param
      when :has_github_token then has_github_token_param
      when :has_claude_token then has_claude_token_param
      when :has_codex_token  then has_codex_token_param
      end
      param ? "yes" : "no"
    end
  end
end
