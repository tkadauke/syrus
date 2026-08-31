module App
  class SpendingFilter
    include Filters::BaseFilter

    LEGACY_URL_KEYS = %w[
      start_date
      end_date
      repository_id
      epic_id
      agent_provider
    ].freeze

    DATE_FIELD = "created_at".freeze

    def self.from_params(params, user:)
      q_tree = Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME])
      legacy_tree = build_tree_from_url_params(params)
      default_tree = default_date_tree unless date_filter_present?(q_tree) || date_filter_present?(legacy_tree)

      tree = [ q_tree, legacy_tree, default_tree ].compact.reduce { |acc, next_tree| merge_and(acc, next_tree) }
      new(tree || Filters::Ast.serialize(Filters::Ast::EMPTY), user: user)
    end

    def initialize(tree, user: nil)
      @ast = Filters::Ast.parse(tree)
      @user = user
    end

    def apply(scope)
      Filters::Compiler.call(@ast, scope: scope, user: @user, subject: :spending_report)
    end

    def date_range
      explicit_date_range || self.class.default_date_range
    end

    def self.schema(user:)
      Filters::Schema.for(subject: :spending_report, user: user)
    end

    def self.default_date_range
      today = Time.zone.today
      [ (today - App::SpendingPayload::DEFAULT_WINDOW_DAYS.days).beginning_of_day, today.end_of_day ]
    end

    def self.default_date_tree
      first_time, last_time = default_date_range
      { "and" => [ chip(DATE_FIELD, "between", [ first_time.iso8601, last_time.iso8601 ]) ] }
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
      if start_date || end_date
        start_time = (start_date || end_date).beginning_of_day
        end_time = (end_date || start_date).end_of_day
        start_time, end_time = end_time, start_time if start_time > end_time
        chips << chip(DATE_FIELD, "between", [ start_time.iso8601, end_time.iso8601 ])
      end

      chips << chip("repository_id", "is", params["repository_id"]) if params["repository_id"].present?
      chips << chip("epic_id", "is", params["epic_id"]) if params["epic_id"].present?
      if User.agent_providers.include?(params["agent_provider"])
        chips << chip("agent_provider", "is", params["agent_provider"])
      end

      return nil if chips.empty?

      { "and" => chips }
    end
    private_class_method :build_tree_from_url_params

    def self.parse_date(value)
      return if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
    private_class_method :parse_date

    def self.date_filter_present?(tree)
      tree_contains_field?(tree, DATE_FIELD)
    end
    private_class_method :date_filter_present?

    def self.tree_contains_field?(node, field)
      return false unless node.is_a?(Hash)
      return node["field"].to_s == field if node.key?("field")

      Array(node["and"]).any? { |child| tree_contains_field?(child, field) } ||
        Array(node["or"]).any? { |child| tree_contains_field?(child, field) } ||
        tree_contains_field?(node["not"], field)
    end
    private_class_method :tree_contains_field?

    private

    def explicit_date_range
      range_from_node(Filters::Ast.serialize(@ast))
    end

    def range_from_node(node)
      return unless node.is_a?(Hash)
      if node["field"] == DATE_FIELD
        return range_from_chip(node)
      end

      Array(node["and"]).each do |child|
        range = range_from_node(child)
        return range if range
      end
      nil
    end

    def range_from_chip(chip)
      if chip["op"] == "between"
        values = Array(chip["value"])
        first_time = parse_time(values.first)
        last_time = parse_time(values.last)
        return [ first_time, last_time ] if first_time && last_time
      elsif chip["op"] == "within_last"
        spec = chip["value"].is_a?(Hash) ? chip["value"] : {}
        duration = Filters::Chips::DateColumn::UNITS[spec["unit"].to_s] * Integer(spec["n"] || 0)
        return [ duration.ago, Time.current ]
      end
    rescue ArgumentError, NoMethodError
      nil
    end

    def parse_time(value)
      return if value.blank?

      Time.zone.parse(value.to_s)
    end
  end
end
