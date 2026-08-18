module Admin
  class EventLogFilterDefinition
    Field = Data.define(
      :name,
      :label,
      :bucket,
      :operators,
      :column,
      :columns,
      :values,
      :default,
      :placeholder,
      :input_mode,
      :apply_proc
    ) do
      def schema
        {
          "field" => name.to_s,
          "label" => label,
          "bucket" => bucket.to_s,
          "operators" => operators.map(&:to_s)
        }.tap do |hash|
          hash["values"] = values if values
          expansions = {}
          expansions["placeholder"] = placeholder if placeholder.present?
          expansions["inputMode"] = input_mode if input_mode.present?
          hash["expansions"] = expansions if expansions.present?
        end
      end

      def apply(scope, op, value)
        return apply_proc.call(scope, op.to_s, value) if apply_proc

        case bucket.to_sym
        when :text, :string then apply_text(scope, op.to_s, value)
        when :enum then apply_enum(scope, op.to_s, value)
        when :number then apply_number(scope, op.to_s, value)
        when :date then apply_date(scope, op.to_s, value)
        else
          raise ArgumentError, "unsupported event log filter bucket: #{bucket.inspect}"
        end
      end

      private

      def apply_text(scope, op, value)
        case op
        when "is", "equals"
          scope.where(column => clean_string(value))
        when "is_not", "not_equals"
          scope.where.not(column => clean_string(value))
        when "contains"
          apply_like(scope, "%#{escape_like(value)}%")
        when "does_not_contain", "not_contains"
          apply_not_like(scope, "%#{escape_like(value)}%")
        when "starts_with"
          apply_like(scope, "#{escape_like(value)}%")
        when "does_not_start_with"
          apply_not_like(scope, "#{escape_like(value)}%")
        when "ends_with"
          apply_like(scope, "%#{escape_like(value)}")
        when "does_not_end_with"
          apply_not_like(scope, "%#{escape_like(value)}")
        when "is_set"
          scope.where.not(column => [ nil, "" ])
        when "is_unset"
          scope.where(column => [ nil, "" ])
        else
          unsupported_op!(op)
        end
      end

      def apply_enum(scope, op, value)
        case op
        when "is"
          scope.where(column => clean_string(value))
        when "is_not"
          scope.where.not(column => clean_string(value))
        when "is_one_of"
          scope.where(column => clean_array(value))
        when "is_none_of"
          scope.where.not(column => clean_array(value))
        when "is_set"
          scope.where.not(column => nil)
        when "is_unset"
          scope.where(column => nil)
        else
          unsupported_op!(op)
        end
      end

      def apply_number(scope, op, value)
        number = numeric(value)
        case op
        when "is", "equals"
          scope.where(column => number)
        when "is_not", "not_equals"
          scope.where.not(column => number)
        when "greater_than"
          scope.where("#{quoted_column(scope, column)} > ?", number)
        when "less_than"
          scope.where("#{quoted_column(scope, column)} < ?", number)
        when "between"
          range = Array(value)
          scope.where(column => numeric(range.first)..numeric(range.last))
        when "is_set"
          scope.where.not(column => nil)
        when "is_unset"
          scope.where(column => nil)
        else
          unsupported_op!(op)
        end
      end

      def apply_date(scope, op, value)
        case op
        when "before"
          scope.where(column => ..parse_time(value))
        when "after"
          scope.where(column => parse_time(value)..)
        when "between"
          range = Array(value)
          scope.where(column => parse_time(range.first)..parse_time(range.last))
        when "within_last"
          scope.where(column => (value.is_a?(Hash) ? duration_for(value).ago : parse_time(value))..)
        when "more_than_ago"
          scope.where(column => ..(value.is_a?(Hash) ? duration_for(value).ago : parse_time(value)))
        when "is_set"
          scope.where.not(column => nil)
        when "is_unset"
          scope.where(column => nil)
        else
          unsupported_op!(op)
        end
      end

      def apply_like(scope, pattern)
        predicates = text_columns.map { |candidate| "#{quoted_column(scope, candidate)} LIKE ? ESCAPE #{like_escape_sql(scope)}" }.join(" OR ")
        scope.where(predicates, *Array.new(text_columns.length, pattern))
      end

      def apply_not_like(scope, pattern)
        predicates = text_columns.map { |candidate| "#{quoted_column(scope, candidate)} NOT LIKE ? ESCAPE #{like_escape_sql(scope)}" }.join(" AND ")
        scope.where(predicates, *Array.new(text_columns.length, pattern))
      end

      def text_columns
        Array(columns.presence || column)
      end

      def clean_string(value)
        Mcp::Tools.utf8(value).strip.safe_byteslice(0, 500)
      end

      def clean_array(value)
        Array(value).map { |item| clean_string(item) }.compact_blank
      end

      def numeric(value)
        Integer(value, exception: false) || Float(value, exception: false) || 0
      end

      def parse_time(value)
        case value
        when Time, DateTime, ActiveSupport::TimeWithZone then value
        when Date then value.in_time_zone
        else Time.zone.parse(value.to_s)
        end
      end

      def duration_for(value)
        spec = value.is_a?(Hash) ? value : {}
        amount = Integer(spec["n"] || spec[:n] || 0)
        unit = (spec["unit"] || spec[:unit]).to_s
        per = {
          "minutes" => 1.minute,
          "hours" => 1.hour,
          "days" => 1.day,
          "weeks" => 1.week,
          "months" => 1.month
        }.fetch(unit)
        per * amount
      end

      def escape_like(value)
        ActiveRecord::Base.sanitize_sql_like(clean_string(value))
      end

      def quoted_column(scope, candidate)
        "#{scope.connection.quote_table_name(scope.table_name)}.#{scope.connection.quote_column_name(candidate)}"
      end

      def like_escape_sql(scope)
        scope.connection.quote("\\")
      end

      def unsupported_op!(op)
        raise ArgumentError, "unsupported operator #{op.inspect} for #{name}"
      end
    end

    class Builder
      def initialize(name, model: nil)
        @definition = EventLogFilterDefinition.new(name, model: model)
      end

      attr_reader :definition

      def field(name, label:, bucket:, operators:, column: nil, columns: nil, values: nil, default: nil, placeholder: nil, input_mode: nil, &apply)
        definition.add_field(
          Field.new(
            name: name.to_s,
            label: label,
            bucket: bucket,
            operators: operators,
            column: (column || name).to_sym,
            columns: columns&.map(&:to_sym),
            values: values,
            default: default,
            placeholder: placeholder,
            input_mode: input_mode,
            apply_proc: apply
          )
        )
      end

      def option_values(values)
        Admin::EventLogFilterDefinitions.option_values(values)
      end

      def revision_scope_values
        Admin::EventLogFilterDefinitions.revision_scope_values
      end

      def per_page_values
        Admin::EventLogFilterDefinitions.per_page_values
      end
    end

    def self.define(name, model: nil, &block)
      builder = Builder.new(name, model: model)
      builder.instance_eval(&block)
      builder.definition
    end

    def initialize(name, model:)
      @name = name.to_sym
      @model = model
      @fields = {}
    end

    attr_reader :name, :model, :fields

    def add_field(field)
      @fields[field.name] = field
    end

    def schema
      fields.values.map(&:schema)
    end

    def filter_tree(params)
      explicit_tree = decoded_q(params) || legacy_tree(params)
      with_defaults(explicit_tree)
    end

    def apply(scope, params)
      EventLogFilterCompiler.new(definition: self).apply(scope, filter_tree(params))
    end

    def flat_filters(params)
      chips = []
      collect_chips(Filters::Ast.parse(filter_tree(params)), chips)
      chips.to_h { |chip| [ chip.field, chip.value ] }
    end

    private

    def decoded_q(params)
      raw = params[:q] || params["q"]
      decoded = Filters::QueryParam.decode(raw)
      return nil unless decoded

      Filters::Ast.serialize(Filters::Ast.parse(decoded))
    rescue ArgumentError
      nil
    end

    def legacy_tree(params)
      chips = fields.values.filter_map do |field|
        raw = params[field.name] || params[field.name.to_sym]
        value = normalize_legacy_value(raw)
        next if value.blank?

        { "field" => field.name, "op" => legacy_op(field), "value" => value }
      end
      { "and" => chips }
    end

    def with_defaults(tree)
      ast = Filters::Ast.parse(tree)
      present = Set.new
      collect_chips(ast, []).each { |chip| present << chip.field }
      children = top_level_children(Filters::Ast.serialize(ast))
      fields.values.each do |field|
        default = field.default.respond_to?(:call) ? field.default.call : field.default
        next if default.blank? || present.include?(field.name)

        children << { "field" => field.name, "op" => legacy_op(field), "value" => default }
      end
      { "and" => children }
    end

    def collect_chips(node, chips)
      case node
      when Filters::Ast::Chip
        chips << node
      when Filters::Ast::AndNode, Filters::Ast::OrNode
        node.children.each { |child| collect_chips(child, chips) }
      when Filters::Ast::NotNode
        collect_chips(node.child, chips)
      end
      chips
    end

    def top_level_children(tree)
      tree.is_a?(Hash) && tree["and"].is_a?(Array) ? tree["and"].dup : [ tree ]
    end

    def legacy_op(field)
      field.operators.first.to_s
    end

    def normalize_legacy_value(raw)
      return nil if raw.nil?

      value = Mcp::Tools.utf8(raw).strip.safe_byteslice(0, 500)
      if (match = value.match(/\A(\d+)([mhd])\z/i))
        unit = { "m" => "minutes", "h" => "hours", "d" => "days" }.fetch(match[2].downcase)
        return { "n" => match[1].to_i, "unit" => unit }
      end
      value
    end
  end
end
