module ReviewContextContributions
  MAX_RESTRICTED_TEXT_BYTES = 128.kilobytes
  class Unavailable < StandardError
    def deterministic? = true
  end

  module_function

  def prepare(target:, run:, evidence:, criteria:)
    provider = provider_for(target)
    result = invoke(provider, :prepare, nil) { provider.prepare(target: target.deep_stringify_keys, run:, evidence:, criteria:) }
    raise Unavailable, "review context provider failed" if result.nil?
    normalize_context(result)
  end

  def prompt(context)
    context.fetch("restricted_text")
  end

  def persist(target:, run:, context:, verdict:, update:)
    provider = provider_for(target)
    receipt = invoke(provider, :persist, nil) { provider.persist(target: target.deep_stringify_keys, run:, context:, verdict:, update:) }
    raise Unavailable, "review context provider failed" if receipt.nil?
    normalize_receipt(receipt)
  end

  def tool_set(target)
    provider = provider_for(target)
    invoke(provider, :tool_set, nil) { provider.tool_set(target.deep_stringify_keys) }
  end

  def tool_capability(target)
    provider = provider_for(target)
    invoke(provider, :tool_capability, nil) { provider.tool_capability(target.deep_stringify_keys) }&.to_sym
  end

  def operator_links(target:, run:, user:)
    provider = provider_for(target)
    invoke(provider, :operator_links, []) { provider.operator_links(target: target.deep_stringify_keys, run:, user:) }
  end

  def provider_for(target)
    type = target.to_h.deep_stringify_keys.fetch("type")
    Syrus::Plugin::ReviewContributions.contributions(:review_context_contributors).find do |candidate|
      invoke(candidate, :target_type, nil) { candidate.target_type } == type
    end ||
      raise(Unavailable, "review context provider is unavailable")
  end

  def invoke(provider, operation, decline, &block)
    result = Syrus::PluginInvocation.call(
      extension_point: :review_context_contributor, provider:, operation:, on_decline: decline, &block
    )
    Syrus::PluginInvocation.value(result)
  end

  def normalize_context(value)
    context = value.to_h.deep_stringify_keys.slice(
      "owner", "type", "version", "manifest", "restricted_text", "persistence_token"
    )
    %w[owner type version].each { |key| raise ArgumentError, "review context #{key} is required" if context[key].blank? }
    raise ArgumentError, "review context manifest must be an object" unless context["manifest"].is_a?(Hash)
    raise ArgumentError, "review context restricted_text must be a string" unless context["restricted_text"].is_a?(String)
    raise ArgumentError, "review context restricted_text is too large" if context["restricted_text"].bytesize > MAX_RESTRICTED_TEXT_BYTES

    deep_freeze(context)
  end

  def normalize_receipt(value)
    receipt = value.to_h.deep_stringify_keys.slice("owner", "type", "key", "version", "persisted_at", "details")
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
