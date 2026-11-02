module Permissions
  class ApprovalProviderRequest
    attr_reader :owner, :capability, :operation, :resource_type, :resource_scope,
      :effects, :invocation_fingerprint, :transcript, :tool_call, :policy_chain, :repository_guidance

    def initialize(owner:, capability:, operation:, resource_type:, resource_scope:, effects:,
      invocation_fingerprint:, transcript:, tool_call:, policy_chain:, repository_guidance: nil)
      @owner = owner
      @capability = capability.to_s
      @operation = operation.to_s
      @resource_type = resource_type.to_s
      @resource_scope = deep_freeze(resource_scope.to_h.deep_stringify_keys)
      @effects = Array(effects).map(&:to_s).uniq.sort.freeze
      @invocation_fingerprint = invocation_fingerprint.to_s
      @transcript = Array(transcript).map { |entry| normalize_transcript_entry(entry) }.freeze
      @tool_call = deep_freeze(tool_call.to_h.deep_stringify_keys)
      @policy_chain = deep_freeze(Array(policy_chain).map { |entry| entry.to_h.deep_stringify_keys })
      @repository_guidance = repository_guidance.to_s.presence&.freeze
      raise ArgumentError, "invocation_fingerprint is required" if @invocation_fingerprint.blank?
      freeze
    end

    def to_h
      {
        "capability" => capability, "operation" => operation, "resource_type" => resource_type,
        "resource_scope" => resource_scope, "effects" => effects,
        "invocation_fingerprint" => invocation_fingerprint, "policy_chain" => policy_chain
      }
    end

    private

    def normalize_transcript_entry(entry)
      normalized = entry.to_h.deep_stringify_keys
      raise ArgumentError, "every transcript entry requires an explicit role" if normalized["role"].blank?

      deep_freeze(normalized)
    end

    def deep_freeze(value)
      case value
      when Hash
        value.to_h { |key, item| [ key.freeze, deep_freeze(item) ] }.freeze
      when Array
        value.map { |item| deep_freeze(item) }.freeze
      else
        value.freeze
      end
    end
  end
end
