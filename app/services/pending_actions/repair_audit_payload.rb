require "digest"

module PendingActions
  # AdminAction.params is a MySQL TEXT column. Keep repair evidence useful and
  # deterministic without copying the (potentially very large) snapshots that
  # already live on ChatPendingAction.
  class RepairAuditPayload
    MAX_BYTES = 60_000
    OPTIONAL_STRING_BYTES = 2_000

    def self.build(pending_action:, record:, outcome: nil)
      new(pending_action, record, outcome).build
    end

    def initialize(pending_action, record, outcome)
      @action = pending_action
      @record = record
      @outcome = outcome
    end

    def build
      payload = {
        pending_action_id: action.id,
        pending_action_group_id: action.pending_action_group_id,
        chat_session_id: action.chat_session_id,
        repository_id: action.repository_id,
        action: action.action.presence || action.action_type,
        reason: bounded_string(action.reason),
        requested_by: action.requested_by,
        payload: bounded_value(action.payload),
        result: result_payload,
        outcome: outcome.presence || (action.before_snapshot == action.after_snapshot ? "noop" : "applied"),
        evidence: {
          before: snapshot_reference(action.before_snapshot),
          after: snapshot_reference(action.after_snapshot)
        }
      }
      return payload if encoded_bytes(payload) <= MAX_BYTES

      # Payload is operator-authored and may contain arbitrary optional data.
      # The target references above are sufficient to retrieve durable detail.
      omitted_bytes = encoded_bytes(payload[:payload])
      payload[:payload] = { "omitted" => true, "bytes" => omitted_bytes }
      payload[:truncation] = { "limit_bytes" => MAX_BYTES, "optional_fields_omitted" => [ "payload" ] }
      raise ArgumentError, "repair audit payload exceeds #{MAX_BYTES} bytes" if encoded_bytes(payload) > MAX_BYTES

      payload
    end

    private

    attr_reader :action, :record, :outcome

    def snapshot_reference(snapshot)
      json = JSON.generate(snapshot)
      {
        captured_at: snapshot.to_h["captured_at"],
        job_ids: Array(snapshot.to_h["jobs"]).filter_map { |job| job["id"] },
        bytes: json.bytesize,
        sha256: Digest::SHA256.hexdigest(json)
      }
    end

    def result_payload
      return unless record
      return record if record.is_a?(Hash)

      { type: record.class.name, id: record.id }
    end

    def bounded_value(value)
      case value
      when Hash
        value.to_h.transform_values { |nested| bounded_value(nested) }
      when Array
        value.map { |nested| bounded_value(nested) }
      when String
        bounded_string(value)
      else
        value
      end
    end

    def bounded_string(value)
      return value if value.blank? || value.bytesize <= OPTIONAL_STRING_BYTES

      prefix = value.byteslice(0, OPTIONAL_STRING_BYTES).to_s.scrub
      "#{prefix}… [truncated; original_bytes=#{value.bytesize}]"
    end

    def encoded_bytes(value)
      JSON.generate(value).bytesize
    end
  end
end
