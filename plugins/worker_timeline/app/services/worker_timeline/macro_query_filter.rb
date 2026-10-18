module WorkerTimeline
  # Compiles the shared filter AST into predicates for each of the macro
  # timeline's three sources. This is intentionally not Filters::Compiler:
  # workflow spans, not-yet-started workflows, and idle InstanceVersions do
  # not share an ActiveRecord relation or even the same set of attributes.
  class MacroQueryFilter
    include Filters::BaseFilter

    DEFAULT_WINDOW = 3.hours
    OPERATORS = {
      "repository_id" => %w[is], "epic_id" => %w[is], "hostname" => %w[is],
      "status" => %w[is_one_of], "job_type" => %w[is_one_of],
      "window" => %w[within_last between]
    }.freeze

    def self.schema = Filters::Schema.for(subject: :worker_timeline)

    def self.from_params(params, smart_folder: nil, user: nil)
      q_tree = Filters::QueryParam.decode(params[Filters::QueryParam::PARAM_NAME])
      tree = [ smart_folder&.filter.presence, q_tree ].compact.reduce { |left, right| merge_and(left, right) }
      new(tree || Filters::Ast.serialize(Filters::Ast::EMPTY), user: user)
    end

    def initialize(tree, user: nil)
      super
      validate!(@ast)
    end

    def from = window_bounds.first
    def to = window_bounds.last

    def matches_workflow?(workflow, source:, attribution: {})
      evaluate(@ast, source:, workflow:, attribution:)
    end

    def matches_instance?(instance)
      evaluate(@ast, source: :idle, instance: instance)
    end

    private

    def window_bounds
      @window_bounds ||= begin
        bounds = positive_window_chips.map { |chip| bounds_for(chip) }
        bounds.empty? ? [ now - DEFAULT_WINDOW, now ] : [ bounds.map(&:first).min, bounds.map(&:last).max ]
      end
    end

    # A negated window is an exclusion inside the normal display range; it
    # must not also shrink that range to the interval being excluded.
    def positive_window_chips(node = @ast, negated: false)
      case node
      when Filters::Ast::Chip
        node.field == "window" && !negated ? [ node ] : []
      when Filters::Ast::AndNode, Filters::Ast::OrNode
        node.children.flat_map { |child| positive_window_chips(child, negated:) }
      when Filters::Ast::NotNode
        positive_window_chips(node.child, negated: !negated)
      else
        []
      end
    end

    def evaluate(node, **context)
      case node
      when Filters::Ast::AndNode then node.children.all? { |child| evaluate(child, **context) }
      when Filters::Ast::OrNode then node.children.any? { |child| evaluate(child, **context) }
      when Filters::Ast::NotNode then !evaluate(node.child, **context)
      when Filters::Ast::Chip then evaluate_chip(node, **context)
      else raise ArgumentError, "unsupported worker timeline filter node: #{node.class}"
      end
    end

    def evaluate_chip(chip, source:, workflow: nil, attribution: {}, instance: nil)
      case chip.field
      when "repository_id" then workflow && workflow.job.repository_id.to_s == chip.value.to_s
      when "epic_id" then workflow && workflow.job.epic_id.to_s == chip.value.to_s
      when "hostname" then (source == :idle ? instance.hostname : attribution[:hostname]).to_s == chip.value.to_s
      when "status" then workflow && Array(chip.value).map(&:to_s).include?(workflow.state)
      when "job_type" then workflow && job_types(chip.value).include?(workflow.job.kind)
      when "window" then overlaps_window?(chip, source:, workflow:, instance:)
      else raise Filters::UnknownFilterField, chip.field
      end
    end

    def overlaps_window?(chip, source:, workflow:, instance:)
      lower, upper = bounds_for(chip)
      started_at, finished_at = case source
      when :span then [ workflow.started_at, workflow.finished_at ]
      when :pending then [ workflow.created_at, workflow.created_at ]
      when :idle then [ instance.started_at, instance.finished_at ]
      end
      started_at && started_at < upper && (finished_at.nil? || finished_at >= lower)
    end

    def bounds_for(chip)
      if chip.op == "between"
        values = Array(chip.value)
        lower = parse_time(values.first)
        upper = [ parse_time(values.last), now ].compact.min
        return [ lower, upper ] if lower && upper && lower <= upper
      else
        duration = duration_for(chip.value)
        return [ now - duration, now ] if duration&.positive?
      end
      raise ArgumentError, "invalid value for worker timeline #{chip.field}:#{chip.op}"
    end

    def job_types(values)
      groups = Array(values).map(&:to_s)
      kinds = []
      kinds.concat(Job::Kind.user_facing_values) if groups.include?("user")
      kinds.concat(Job::Kind.infrastructure_values) if groups.include?("system")
      kinds.uniq
    end

    def validate!(node)
      case node
      when Filters::Ast::AndNode, Filters::Ast::OrNode
        node.children.each { |child| validate!(child) }
      when Filters::Ast::NotNode then validate!(node.child)
      when Filters::Ast::Chip
        supported = OPERATORS[node.field] or raise Filters::UnknownFilterField, node.field
        raise ArgumentError, "unsupported operator #{node.op.inspect} for worker timeline field #{node.field.inspect}" unless supported.include?(node.op)
        bounds_for(node) if node.field == "window"
      else
        raise ArgumentError, "unsupported worker timeline filter node: #{node.class}"
      end
    end

    def now = @now ||= Time.current

    def parse_time(value)
      return value if value.respond_to?(:iso8601)
      return nil if value.blank?
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def duration_for(value)
      return nil unless value.is_a?(Hash)
      spec = value.transform_keys(&:to_s)
      unit = Filters::Chips::DateColumn::UNITS[spec["unit"].to_s]
      amount = Integer(spec["n"], exception: false)
      unit * amount if unit && amount
    end
  end
end
