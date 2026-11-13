module Permissions
  class HistoryFilter
    SCHEMA = [
      { "field" => "capability", "label" => "Capability or operation", "bucket" => "text", "operators" => %w[contains is] },
      { "field" => "outcome", "label" => "Outcome", "bucket" => "enum", "operators" => %w[is is_not is_one_of],
        "values" => %w[approved denied pending confirmed executed failed revoked expired exhausted active] },
      { "field" => "actor", "label" => "Agent or role", "bucket" => "text", "operators" => %w[contains is] },
      { "field" => "context", "label" => "Chat or job", "bucket" => "text", "operators" => %w[contains is] },
      { "field" => "occurred_at", "label" => "Date", "bucket" => "date",
        "operators" => %w[before after between within_last more_than_ago], "date_precision" => "datetime" }
    ].freeze

    def self.schema = SCHEMA

    def initialize(tree)
      @ast = Filters::Ast.parse(tree)
    end

    def match?(entry)
      evaluate(@ast, entry)
    end

    private

    def evaluate(node, entry)
      case node
      when Filters::Ast::AndNode then node.children.all? { |child| evaluate(child, entry) }
      when Filters::Ast::OrNode then node.children.any? { |child| evaluate(child, entry) }
      when Filters::Ast::NotNode then !evaluate(node.child, entry)
      when Filters::Ast::Chip then match_chip?(node, entry)
      else false
      end
    end

    def match_chip?(chip, entry)
      return match_date?(chip, entry.fetch(:occurred_at)) if chip.field == "occurred_at"

      values = values_for(chip.field, entry)
      expected = Array(chip.value).map { |value| value.to_s.downcase }
      actual = values.map { |value| value.to_s.downcase }
      matched = chip.op == "contains" ? actual.any? { |value| expected.any? { |item| value.include?(item) } } : (actual & expected).any?
      chip.op == "is_not" ? !matched : matched
    end

    def values_for(field, entry)
      case field
      when "capability"
        [ entry[:capability], entry[:operation], *Array(entry[:items]).flat_map { |item| [ item[:capability], item[:operation] ] } ].compact
      when "outcome"
        [ entry[:state], entry[:result_status], *Array(entry[:items]).map { |item| item[:state] } ].compact
      when "actor"
        references(entry, :actor, :claimant, :issued_by, :revoked_by, :decision_principal) +
          Array(entry[:items]).flat_map { |item| references(item, :decision_principal, :authority) } +
          [ entry[:requested_by], entry[:subject] ].compact
      when "context"
        references(entry, :origin, :origins) + Array(entry[:origins]).flat_map { |origin| [ origin[:type], origin[:id] ] }
      else
        raise ArgumentError, "unknown permission history filter field: #{field.inspect}"
      end
    end

    def references(entry, *keys)
      keys.flat_map { |key| Array(entry[key]) }.flat_map { |reference| reference.is_a?(Hash) ? reference.values_at(:label, :type, :id) : reference }.compact
    end

    def match_date?(chip, occurred_at)
      time = occurred_at.to_time
      case chip.op
      when "before" then time < Time.zone.parse(chip.value.to_s)
      when "after" then time > Time.zone.parse(chip.value.to_s)
      when "between"
        from, to = Array(chip.value).map { |value| Time.zone.parse(value.to_s) }
        time.between?(from, to)
      when "within_last" then time >= relative_time(chip.value)
      when "more_than_ago" then time < relative_time(chip.value)
      else raise ArgumentError, "unsupported date operator: #{chip.op.inspect}"
      end
    end

    def relative_time(value)
      amount = value.to_h.fetch("n").to_i
      unit = value.to_h.fetch("unit").to_s
      amount.public_send(unit).ago
    end
  end
end
