module App
  class SpendingFilter
    include Filters::BaseFilter

    DEFAULT_WINDOW_DAYS = 90
    LEGACY_URL_KEYS = %w[
      start_date
      end_date
      repository_id
      epic_id
      user_id
      agent_provider
      trigger_kind
    ].freeze

    def self.from_params(params, user:)
      q_tree = Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME])
      url_tree = build_tree_from_url_params(params)
      trees = [ q_tree, url_tree ].compact
      trees.unshift(default_tree) unless trees.any? { |tree| tree_fields(tree).include?("created_at") }
      tree = trees.reduce { |acc, next_tree| merge_and(acc, next_tree) }

      new(tree, user: user)
    end

    def initialize(tree, user:)
      @ast = Filters::Ast.parse(tree)
      @user = user
    end

    def apply(scope)
      Filters::Compiler.call(@ast, scope: scope, user: @user, subject: :spending_report)
    end

    def start_date
      bounds.fetch(:start_date)
    end

    def end_date
      bounds.fetch(:end_date)
    end

    def fields
      chips.map(&:field)
    end

    def exact_value(field)
      chips.select { |chip| chip.field == field && chip.op.to_sym == :is }.last&.value
    end

    private

    attr_reader :user

    def bounds
      @bounds ||= begin
        dates = chips.select { |chip| chip.field == "created_at" }.filter_map { |chip| dates_for(chip) }
        {
          start_date: dates.map(&:first).compact.max || default_start_date,
          end_date: dates.map(&:last).compact.min || default_end_date
        }.then do |range|
          range[:start_date] > range[:end_date] ? { start_date: range[:end_date], end_date: range[:start_date] } : range
        end
      end
    end

    def dates_for(chip)
      case chip.op.to_sym
      when :between
        values = Array(chip.value)
        [ parse_date(values.first), parse_date(values.last) ]
      when :after
        [ parse_date(chip.value), nil ]
      when :before
        [ nil, parse_date(chip.value) ]
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
      start_date = parse_date(params["start_date"])
      end_date = parse_date(params["end_date"])
      chips << chip("created_at", "between", [ start_date.iso8601, end_date.iso8601 ]) if start_date && end_date
      chips << chip("repository_id", "is", params["repository_id"]) if params["repository_id"].present?
      chips << chip("epic_id", "is", params["epic_id"]) if params["epic_id"].present?
      chips << chip("user_id", "is", params["user_id"]) if params["user_id"].present?
      chips << chip("agent_provider", "is", params["agent_provider"]) if User.agent_providers.include?(params["agent_provider"])
      chips << chip("trigger_kind", "is", params["trigger_kind"]) if Run::TRIGGER_KINDS.include?(params["trigger_kind"])

      return nil if chips.empty?

      { "and" => chips }
    end
    private_class_method :build_tree_from_url_params

    def self.default_tree
      end_date = Time.zone.today
      start_date = end_date - DEFAULT_WINDOW_DAYS.days
      { "and" => [ chip("created_at", "between", [ start_date.iso8601, end_date.iso8601 ]) ] }
    end
    private_class_method :default_tree

    def self.parse_date(value)
      return if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
    private_class_method :parse_date

    def self.tree_fields(tree)
      Filters::Ast.parse(tree).then { |ast| collect_fields(ast) }
    rescue ArgumentError
      []
    end
    private_class_method :tree_fields

    def self.collect_fields(node)
      case node
      when Filters::Ast::Chip
        [ node.field ]
      when Filters::Ast::AndNode, Filters::Ast::OrNode
        node.children.flat_map { |child| collect_fields(child) }
      when Filters::Ast::NotNode
        collect_fields(node.child)
      else
        []
      end
    end
    private_class_method :collect_fields

    def parse_date(value)
      self.class.send(:parse_date, value)
    end

    def default_end_date
      Time.zone.today
    end

    def default_start_date
      default_end_date - DEFAULT_WINDOW_DAYS.days
    end
  end
end
