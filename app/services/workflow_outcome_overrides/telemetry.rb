module WorkflowOutcomeOverrides
  class Telemetry
    LOG_KIND = "workflow_outcome_override".freeze

    Syrus::Metrics.declare do
      counter :workflow_outcome_overrides_consumed_total, tags: %i[kind source],
              comment: "Exact-evidence workflow outcome overrides consumed, by gate kind and request channel"
    end

    def self.record_consumed(override)
      Syrus::Metrics.counter(:syrus_workflow_outcome_overrides_consumed_total)
        .increment(tags: { kind: override.gate_kind, source: override.channel })

      OperationalLogging.ingest(
        level: :info,
        source: LOG_KIND,
        message: I18n.t("services.workflow_outcome_overrides.telemetry.message"),
        context: {
          job_id: override.job_id,
          workflow_id: override.workflow_id,
          step_id: override.step_id,
          outcome_override_id: override.id,
          gate_kind: override.gate_kind,
          gate_identity: override.gate_identity,
          candidate_head_sha: override.candidate_head_sha,
          evidence_digest: override.evidence_digest,
          actor_type: override.actor_type,
          actor_id: override.actor_id,
          channel: override.channel
        }
      )

      run = override.step&.runs&.order(:created_at)&.last
      return unless run

      JobLog.append!(
        run:,
        kind: LOG_KIND,
        chunk: transcript_chunk(override)
      )
    rescue StandardError => error
      Rails.logger.warn("[WorkflowOutcomeOverrides::Telemetry] recording failed: #{error.class}: #{error.message}")
      nil
    end

    def self.transcript_chunk(override)
      text = I18n.t(
        "services.workflow_outcome_overrides.telemetry.transcript",
        gate_kind: override.gate_kind,
        gate_identity: override.gate_identity,
        candidate_head_sha: override.candidate_head_sha.first(12),
        evidence_digest: override.evidence_digest.first(12)
      )
      "#{ToolPayloadRedactor.redact_text(text).gsub(/[[:space:]]+/, " ").strip}\n"
    end
    private_class_method :transcript_chunk
  end
end
