module ReviewContextContributions
  class Unavailable < StandardError
    def deterministic? = true
  end

  module_function

  def prepare(target:, run:, evidence:, criteria:)
    provider = provider_for(target)
    result = provider.prepare(target: target.deep_stringify_keys, run:, evidence:, criteria:)
    normalize_context(result)
  end

  def prompt(context)
    context.fetch("restricted_text")
  end

  def persist(target:, run:, context:, verdict:, update:)
    provider = provider_for(target)
    receipt = provider.persist(target: target.deep_stringify_keys, run:, context:, verdict:, update:)
    normalize_receipt(receipt)
  end

  def tool_set(target)
    provider_for(target).tool_set(target.deep_stringify_keys)
  end

  def provider_for(target)
    type = target.to_h.deep_stringify_keys.fetch("type")
    Syrus::PluginRegistry.providers_for(:review_context_contributor).find { |candidate| candidate.target_type == type } ||
      raise(Unavailable, "review context provider is unavailable")
  end

  def normalize_context(value)
    context = value.to_h.deep_stringify_keys.slice("manifest", "restricted_text", "persistence_token")
    raise ArgumentError, "review context manifest must be an object" unless context["manifest"].is_a?(Hash)
    raise ArgumentError, "review context restricted_text must be a string" unless context["restricted_text"].is_a?(String)

    deep_freeze(context)
  end

  def normalize_receipt(value)
    receipt = value.to_h.deep_stringify_keys.slice("owner", "type", "key", "version", "persisted_at")
    %w[owner type key version].each { |key| raise ArgumentError, "persistence receipt #{key} is required" if receipt[key].blank? }
    deep_freeze(receipt)
  end

  def deep_freeze(value)
    case value
    when Hash then value.to_h { |key, item| [ key.freeze, deep_freeze(item) ] }.freeze
    when Array then value.map { |item| deep_freeze(item) }.freeze
    else value.freeze
    end
  end
end
