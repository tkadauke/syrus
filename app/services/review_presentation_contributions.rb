module ReviewPresentationContributions
  COLLECTIONS = %i[target_editors evidence_renderers audit_renderers settings_summaries].freeze
  FRONTEND_KINDS = {
    target_editors: "target_editor", evidence_renderers: "evidence", audit_renderers: "audit",
    settings_summaries: "settings_summary"
  }.freeze

  module_function

  def payload
    result = providers.each_with_object(COLLECTIONS.to_h { |collection| [ collection, [] ] }) do |provider, collections|
      COLLECTIONS.each do |collection|
        result = invoke(provider, collection, []) { provider.public_send(collection) }
        collections[collection].concat(normalize(result, collection:))
      end
    end
    result[:translation_namespaces] = providers.flat_map do |provider|
      Array(invoke(provider, :translation_namespaces, []) { provider.translation_namespaces })
    end.map(&:to_s).uniq
    result
  end

  def render_audit(snapshot)
    key = snapshot.to_h.deep_stringify_keys["renderer"]
    renderer = payload[:audit_renderers].find { |entry| entry["key"] == key }
    renderer ? { "component" => renderer["component"], "payload" => snapshot.to_h.deep_stringify_keys["payload"] } : snapshot
  end

  def frontend_payload
    contributions = payload
    FRONTEND_KINDS.flat_map do |collection, kind|
      contributions.fetch(collection).map { |entry| entry.merge("kind" => kind) }
    end
  end

  def providers = Syrus::Plugin::ReviewContributions.contributions(:review_presentation_contributors)

  def invoke(provider, operation, decline, &block)
    result = Syrus::PluginInvocation.call(
      extension_point: :review_presentation_contributor, provider:, operation:, on_decline: decline, &block
    )
    Syrus::PluginInvocation.value(result)
  end

  def normalize(entries, collection:)
    Array(entries).map do |entry|
      value = entry.to_h.deep_stringify_keys
      %w[key component].each { |key| raise ArgumentError, "#{collection} contribution #{key} is required" if value[key].blank? }
      raise ArgumentError, "#{collection} contribution aria_label_key is required" if value["aria_label_key"].blank?
      value.slice("key", "component", "target_type", "artifact_type", "trigger_kinds", "target_required",
        "label_key", "description_key", "aria_label_key")
    end
  end
end
