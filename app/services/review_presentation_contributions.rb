module ReviewPresentationContributions
  COLLECTIONS = %i[target_editors evidence_renderers audit_renderers settings_summaries translations].freeze
  FRONTEND_KINDS = {
    target_editors: "target_editor", evidence_renderers: "evidence", audit_renderers: "audit",
    settings_summaries: "settings_summary"
  }.freeze

  module_function

  def payload
    providers.each_with_object(COLLECTIONS.to_h { |collection| [ collection, [] ] }) do |provider, result|
      COLLECTIONS.each do |collection|
        result[collection] ||= []
        result[collection].concat(normalize(provider.public_send(collection), collection:))
      end
    end
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

  def providers = Syrus::PluginRegistry.providers_for(:review_presentation_contributor)

  def normalize(entries, collection:)
    Array(entries).map do |entry|
      value = entry.to_h.deep_stringify_keys
      %w[key component].each { |key| raise ArgumentError, "#{collection} contribution #{key} is required" if value[key].blank? }
      value.slice("key", "component", "target_type", "artifact_type", "label_key", "description_key", "aria_label_key")
    end
  end
end
