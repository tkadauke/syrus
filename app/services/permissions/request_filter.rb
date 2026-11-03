module Permissions
  # Server-side filtering and option discovery for the permission inbox. The
  # filter arrives as the shared Filters AST (an AND of chips); every chip is
  # applied to the relation before counting and pagination. Option payloads are
  # derived from the same visibility-safe scope, never from one loaded page.
  class RequestFilter
    FIELDS = %w[state subject action effect origin_type].freeze
    STATES = %w[pending confirmed rejected dismissed non_actionable].freeze

    def initialize(scope, tree)
      @scope = scope
      @chips = chips_from(tree)
    end

    def apply
      @chips.reduce(@scope) { |relation, chip| narrow(relation, chip.field, values_for(chip)) }
    end

    # Labeled choices for every filter field, complete for the whole scope.
    def options
      items = PendingActionItem.where(chat_pending_action_id: @scope.select(:id))
      {
        state: STATES.map { |state| { value: state, label: RequestPresentation.state_label(state) } },
        subject: subject_options,
        action: action_options(items),
        effect: effect_options(items),
        origin_type: @scope.where.not(origin_type: nil).distinct.pluck(:origin_type).sort
          .map { |type| { value: type, label: RequestPresentation.origin_type_label(type) } }
      }
    end

    private

    def chips_from(tree)
      node = Filters::Ast.parse(tree)
      children = node.is_a?(Filters::Ast::AndNode) ? node.children : [ node ]
      children.select { |child| child.is_a?(Filters::Ast::Chip) && child.field.in?(FIELDS) }
    rescue ArgumentError
      []
    end

    def values_for(chip) = Array(chip.value).map(&:to_s).reject(&:blank?)

    def narrow(relation, field, values)
      return relation if values.empty?

      case field
      when "state" then relation.where(state: values)
      when "origin_type" then relation.where(origin_type: values)
      when "subject" then narrow_subject(relation, values)
      when "action" then relation.where(id: PendingActionItem.where("operation IN (:v) OR (operation IS NULL AND capability IN (:v))", v: values).select(:chat_pending_action_id))
      when "effect" then relation.where(id: ids_with_effect(values))
      else relation
      end
    end

    def narrow_subject(relation, values)
      pairs = subject_pairs(values)
      return relation.none if pairs.empty?

      relation.where(Array.new(pairs.size, "(chat_pending_actions.subject_type = ? AND chat_pending_actions.subject_id = ?)").join(" OR "), *pairs.flatten)
    end

    def subject_pairs(values)
      values.filter_map do |value|
        type, id = value.split(":", 2)
        [ type, id.to_i ] if type.present? && id.to_i.positive?
      end
    end

    # effects is a JSON column, so matching is done on the (small) distinct set
    # rather than with dialect-specific JSON operators.
    def ids_with_effect(values)
      PendingActionItem.where(chat_pending_action_id: @scope.select(:id)).pluck(:chat_pending_action_id, :effects)
        .filter_map { |id, effects| id if (Array(effects).map(&:to_s) & values).any? }.uniq
    end

    def subject_options
      pairs = @scope.where.not(subject_id: nil).distinct.pluck(:subject_type, :subject_id)
      pairs.group_by(&:first).flat_map do |type, group|
        klass = type.safe_constantize
        next [] unless klass

        klass.where(id: group.map(&:last)).map do |record|
          { value: "#{type}:#{record.id}", label: RequestPresentation.subject_label(record) }
        end
      end.sort_by { |option| option[:label].downcase }
    end

    def action_options(items)
      items.distinct.pluck(:capability, :operation, :effects).each_with_object({}) do |(capability, operation, effects), found|
        key = operation.presence || capability
        found[key] ||= { value: key, label: RequestPresentation.action_label(capability:, operation:, effects:) }
      end.values.sort_by { |option| option[:label].downcase }
    end

    def effect_options(items)
      items.distinct.pluck(:effects).flat_map { |effects| Array(effects).map(&:to_s) }.uniq
        .select { |effect| effect.in?(RequestPresentation::EFFECT_KEYS) }
        .map { |effect| { value: effect, label: RequestPresentation.effect_label(effect) } }
        .sort_by { |option| option[:label].downcase }
    end
  end
end
