module Permissions
  # The single plain-English contract for an authorization request, consumed by
  # every operator surface (chat card, approval inbox, global drawer, Job
  # detail). Wording comes from the request's own purpose, the pending-action
  # presenter (App::Presentation), the capability catalog, and typed resource
  # labels -- never from raw capability/operation keys, JSON, or database ids.
  # Redacted audit evidence stays on the audit-oriented payload fields.
  class RequestPresentation
    EFFECT_KEYS = CapabilityDescriptor::EFFECTS.map(&:to_s).freeze
    ORIGIN_TYPES = %w[Job ChatSession].freeze

    class << self
      def effect_label(effect) = I18n.t("permission_presentation.effects.#{effect}", default: I18n.t("permission_presentation.effects.unknown"))

      def state_label(state) = I18n.t("permission_presentation.states.#{state}", default: state.to_s.humanize)

      def origin_type_label(type) = I18n.t("permission_presentation.origin_types.#{type}", default: I18n.t("permission_presentation.origin_types.other"))

      # Human sentence for one operation/capability pair. Catalog wording is
      # preferred; otherwise the sentence is built from the declared effects.
      def action_label(capability:, operation:, effects: [])
        key = lookup_key(operation.presence || capability)
        specific = I18n.t("permission_presentation.actions.#{key}", default: nil)
        return specific if specific.present?

        consequence = consequence_phrases(effects).first
        consequence ? I18n.t("permission_presentation.action_fallback_with_effect", effect: consequence) : I18n.t("permission_presentation.action_fallback")
      end

      def consequence_phrases(effects)
        Array(effects).map(&:to_s).uniq.filter_map { |effect| effect_label(effect) if effect.in?(EFFECT_KEYS) }
      end

      def subject_label(subject)
        [ subject&.try(:name), subject&.try(:title) ].find(&:present?) || I18n.t("permission_presentation.agent_fallback")
      end

      def lookup_key(value) = value.to_s.sub(/@v\d+\z/, "").gsub(/[^a-zA-Z0-9_]/, "_")
    end

    def initialize(request, current_user: nil)
      @request = request
      @current_user = current_user
    end

    # Request-level card copy. Optional context is omitted when blank.
    def as_json
      items = request.authorization_items.sort_by(&:id).map { |item| item_json(item) }
      statement = request.purpose.presence || items.map { |item| item[:statement] }.uniq.to_sentence.presence || I18n.t("permission_presentation.fallback_statement")
      {
        statement:,
        agent: agent_label,
        origin: origin_label,
        scope: items.map { |item| item[:scope] }.compact.uniq.to_sentence.presence,
        consequences: items.flat_map { |item| item[:consequences] }.uniq,
        why_approval_required: items.map { |item| item[:why_approval_required] }.compact.uniq.first,
        requested_durations: items.map { |item| item[:requested_durations] }.reduce(:&) || []
      }.compact_blank
    end

    def item_json(item)
      {
        statement: item_statement(item),
        scope: scope_label(item),
        consequences: self.class.consequence_phrases(item.effects),
        why_approval_required: why_required(item),
        requested_durations: Array(item.requested_durations).map { |d| I18n.t("permission_presentation.durations.#{d}", default: nil) }.compact
      }.compact_blank
    end

    private

    attr_reader :request

    def agent_label
      self.class.subject_label(request.subject) if request.subject || request.runtime_role.present?
    end

    def origin_label
      origin = request.origin
      return unless origin

      type = self.class.origin_type_label(origin.class.base_class.name)
      title = [ origin.try(:title), origin.try(:name) ].find(&:present?)
      title.present? ? I18n.t("permission_presentation.origin_with_title", type:, title:) : type
    end

    def item_statement(item)
      if item.kind == "capability_possession"
        I18n.t("permission_presentation.capability_possession", action: self.class.action_label(capability: item.capability, operation: nil, effects: item.effects).downcase_first)
      else
        self.class.action_label(capability: item.capability, operation: item.operation, effects: item.effects)
      end
    end

    def scope_label(item)
      descriptor = Catalog.find!(capability: item.capability, operation: item.operation)
      scope = item.resource_scope
      return if scope.blank?

      result = descriptor.resource_scope.label(scope, context: { user: @current_user })
      result.success? ? result.value : nil
    rescue Catalog::UnknownCapability
      nil
    end

    def why_required(item)
      source = item.decisive_rule.is_a?(Hash) ? item.decisive_rule["source"].to_s : ""
      policy = item.decisive_rule.is_a?(Hash) ? item.decisive_rule["policy"].to_s : ""
      return if source.blank? && policy.blank?

      [ source, policy ].filter_map { |key| I18n.t("permission_presentation.why.#{key}", default: nil).presence if key.present? }.first
    end
  end
end
