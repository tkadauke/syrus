module Admin
  module Users
    class Filter
      include Filters::BaseFilter

      LEGACY_URL_KEYS = %w[ email admin has_github_token has_claude_token has_codex_token gh_rate ].freeze

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
        Filters::Compiler.call(@ast, scope: scope, user: @user, subject: :admin_user)
      end

      def any?
        active?
      end

      def active_filters
        chips.each_with_object({}) do |chip, filters|
          filters[chip.field] = display_value(chip)
        end
      end

      private

      def display_value(chip)
        case chip.field
        when "admin", "has_github_token", "has_claude_token", "has_codex_token"
          ActiveModel::Type::Boolean.new.cast(chip.value) ? "yes" : "no"
        else
          chip.value
        end
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
        email = params["email"].to_s.strip
        chips << chip("email", "contains", email) if email.present?

        %w[ admin has_github_token has_claude_token has_codex_token ].each do |key|
          value = normalize_bool(params[key])
          chips << chip(key, "is", value.to_s) unless value.nil?
        end

        gh_rate = params["gh_rate"].to_s.downcase
        chips << chip("gh_rate", "is", gh_rate) if %w[ low exhausted ].include?(gh_rate)

        return nil if chips.empty?

        { "and" => chips }
      end
      private_class_method :build_tree_from_url_params

      def self.normalize_bool(value)
        return nil if value.nil?

        case value.to_s.downcase
        when "true", "1", "yes" then true
        when "false", "0", "no" then false
        end
      end
      private_class_method :normalize_bool
    end
  end
end
