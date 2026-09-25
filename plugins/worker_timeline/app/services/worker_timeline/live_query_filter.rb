module WorkerTimeline
  class LiveQueryFilter
    DEFAULT_WINDOW = 1.hour
    STATUS_VALUES = %w[idle busy degraded overloaded].freeze

    def self.schema
      [
        { field: "hostname", label: "Hostname", bucket: "fk", operators: [ "is" ], typeahead: true },
        {
          field: "status",
          label: "Status",
          bucket: "enum",
          operators: [ "is_one_of" ],
          values: STATUS_VALUES.map { |status| { value: status, label: status.humanize } }
        },
        { field: "window", label: "Health window", bucket: "date", operators: [ "within_last", "between" ] }
      ]
    end

    def self.from_params(params)
      new(Filters::QueryParam.decode(params[:q]))
    end

    def self.from_direct_params(params)
      chips = []
      chips << Filters::Ast::Chip.new(field: "hostname", op: "is", value: params[:hostname]) if params[:hostname].present?
      chips << Filters::Ast::Chip.new(field: "status", op: "is_one_of", value: params[:status]) if params[:status].present?
      new(Filters::Ast.serialize(Filters::Ast::AndNode.new(children: chips)), from: params[:from], to: params[:to])
    end

    def initialize(tree, from: nil, to: nil)
      @chips = top_level_chips(Filters::Ast.parse(tree))
      @from_override = parse_time(from)
      @to_override = parse_time(to)
    end

    def to_h
      Filters::Ast.serialize(Filters::Ast::AndNode.new(children: chips))
    end

    def hostname = chip_value("hostname").presence

    def statuses
      Array(chip_value("status")).flat_map { |value| value.to_s.split(",") }.select { |value| STATUS_VALUES.include?(value) }.presence
    end

    def from
      return @from_override if @from_override
      return now - DEFAULT_WINDOW unless window_chip

      if window_chip.op == "between"
        parse_time(Array(window_chip.value).first) || now - DEFAULT_WINDOW
      else
        duration_for(window_chip.value)&.ago || now - DEFAULT_WINDOW
      end
    end

    def to
      return [ @to_override, now ].compact.min if @to_override
      return now unless window_chip&.op == "between"

      [ parse_time(Array(window_chip.value).last) || now, now ].min
    end

    private

    attr_reader :chips

    def now = @now ||= Time.current

    def top_level_chips(node)
      return [ node ] if node.is_a?(Filters::Ast::Chip)
      return node.children.select { |child| child.is_a?(Filters::Ast::Chip) } if node.is_a?(Filters::Ast::AndNode)

      []
    end

    def chip_value(field)
      chips.find { |chip| chip.field == field }&.value
    end

    def window_chip
      chips.find { |chip| chip.field == "window" }
    end

    def parse_time(value)
      return nil if value.blank?
      return value if value.respond_to?(:iso8601)

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def duration_for(value)
      return nil unless value.is_a?(Hash)

      spec = value.transform_keys(&:to_s)
      per = Filters::Chips::DateColumn::UNITS[spec["unit"].to_s]
      return nil unless per

      per * (Integer(spec["n"], exception: false) || 0)
    end
  end
end
