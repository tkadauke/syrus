class NeutralizeFalseCodexUsageLimitEvidence < ActiveRecord::Migration[8.1]
  FALSE_POSITIVE_PATTERNS = [
    "failed to refresh available models",
    "failed to refresh model metadata",
    "stream disconnected before completion",
    "failed to decode models response",
    "unknown variant"
  ].freeze

  def up
    rows = select_all(<<~SQL.squish)
      SELECT id, details
      FROM provider_availability_evidences
      WHERE provider = 'codex'
        AND status = 'exhausted'
        AND source = 'codex_invocation_failure'
    SQL

    rows.each do |row|
      details = decode_details(row["details"])
      message = details["message"].to_s.downcase
      next unless FALSE_POSITIVE_PATTERNS.any? { |pattern| message.include?(pattern) }

      details["neutralized_reason"] = "codex_model_metadata_refresh_inconclusive"
      execute(<<~SQL.squish)
        UPDATE provider_availability_evidences
        SET status = 'probe_inconclusive',
            details = #{quote(encode_details(details))},
            updated_at = #{quote(Time.current)}
        WHERE id = #{Integer(row["id"])}
      SQL
    end
  end

  def down
    rows = select_all(<<~SQL.squish)
      SELECT id, details
      FROM provider_availability_evidences
      WHERE provider = 'codex'
        AND status = 'probe_inconclusive'
        AND source = 'codex_invocation_failure'
    SQL

    rows.each do |row|
      details = decode_details(row["details"])
      next unless details["neutralized_reason"] == "codex_model_metadata_refresh_inconclusive"

      details.delete("neutralized_reason")
      execute(<<~SQL.squish)
        UPDATE provider_availability_evidences
        SET status = 'exhausted',
            details = #{quote(encode_details(details))},
            updated_at = #{quote(Time.current)}
        WHERE id = #{Integer(row["id"])}
      SQL
    end
  end

  private

  def decode_details(value)
    case value
    when Hash then value
    when String then JSON.parse(value.presence || "{}")
    else {}
    end
  rescue JSON::ParserError
    {}
  end

  def encode_details(value)
    connection.adapter_name.match?(/sqlite/i) ? JSON.generate(value) : value
  end
end
