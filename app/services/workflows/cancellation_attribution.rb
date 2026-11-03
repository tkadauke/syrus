require "securerandom"

module Workflows
  # Durable root-cause attribution for Workflow cancellations and the
  # cascades they trigger.
  #
  # The root event is written into the root Workflow's `artifacts["cancellation"]`
  # *before* terminal cleanup begins (LifecyclePropagation#cancelled! ensures
  # it). Cleaned-up descendants (Steps via `details`, other Workflows via their
  # own `artifacts["cancellation"]`) carry only a reference -- event id,
  # cascade id, root workflow id and immediate causal parent -- so cleanup
  # mechanics (`cancelled_by: terminal_workflow_cleanup`) can never replace
  # the original cause. Runs derive theirs from their Step.
  #
  # Recording is idempotent: an existing attribution is never overwritten.
  # Legacy records without one serialize as `attribution_available: false`.
  class CancellationAttribution
    ARTIFACT_KEY = "cancellation".freeze
    STEP_DETAIL_KEY = "cancellation_attribution".freeze
    UNKNOWN_INITIATOR = "unknown".freeze

    # One entry per distinguishable cause. `reasons` are exact cancellation
    # reason strings, `prefixes` match reason families.
    Kind = Struct.new(:key, :reasons, :prefixes, keyword_init: true) do
      def matches?(reason)
        reasons.include?(reason) || prefixes.any? { |prefix| reason.start_with?(prefix) }
      end
    end

    KINDS = [
      Kind.new(key: "operator_cancellation", reasons: %w[operator_cancelled operator_stopped_landing operator_stale_work_repair], prefixes: []),
      Kind.new(key: "stack_topology_repair", reasons: %w[superseded_by_rebase], prefixes: %w[stack_rebase]),
      Kind.new(key: "supersession", reasons: %w[superseded_by_newer_workflow emergency_land_superseded superseded coding_handoff_takeover], prefixes: %w[superseded_base]),
      Kind.new(key: "dependency_invalidation", reasons: %w[job_closed job_approved], prefixes: %w[dependency_]),
      Kind.new(key: "provider_rerouting", reasons: %w[stale_provider_relaunch], prefixes: %w[provider_relaunch]),
      Kind.new(key: "automatic_recovery", reasons: %w[superseded_by_state_repair workflow_runaway], prefixes: %w[recovery_]),
      Kind.new(key: "infrastructure_shutdown", reasons: %w[worker_shutdown], prefixes: %w[infrastructure_shutdown])
    ].freeze
    DIRECT_KIND = "direct_cancellation".freeze
    UNATTRIBUTED_KIND = "unattributed".freeze
    CAUSE_KEYS = %w[kind initiator_class initiator_id control_path reason source parent_workflow_id].freeze
    SOURCE_ID_KEY = /(\A|_)(id|ids|slug|number)\z/

    def self.declare_metrics!
      Syrus::Metrics.declare do
        counter :workflow_cancellations_total, tags: %i[kind],
                comment: "Workflow cancellations recorded with root-cause attribution, by cause kind"
        counter :workflow_cancellations_unattributed_total, tags: %i[kind],
                comment: "Workflow cancellations reaching terminal cleanup with no attributed cause (invariant violation)"
      end
    end
    declare_metrics!

    # Runs the block with an ambient cause that cancellations performed
    # inside it inherit when they pass none explicitly.
    def self.with_cause(cause)
      previous = Current.cancellation_cause
      Current.cancellation_cause = cause
      yield
    ensure
      Current.cancellation_cause = previous
    end

    # While a Workflow's terminal propagation runs, every other cancellation it
    # triggers (job lifecycle, hooks, dependents) is a child of that Workflow.
    def self.with_parent(workflow)
      previous = [ Current.cancellation_parent_workflow_id, Current.cancellation_parent_event ]
      Current.cancellation_parent_workflow_id = workflow.id
      # The parent's event is still in memory (its transition is not saved yet).
      Current.cancellation_parent_event = workflow.artifacts.to_h[ARTIFACT_KEY]
      yield
    ensure
      Current.cancellation_parent_workflow_id, Current.cancellation_parent_event = previous
    end

    def self.kind_for(reason)
      reason = reason.to_s
      KINDS.find { |kind| kind.matches?(reason) }&.key || DIRECT_KIND
    end

    # Records the root event on `workflow` (in memory; callers persist it
    # with the cancel transition). No-op when already attributed.
    def self.record!(workflow, reason:, cause: nil)
      new(workflow).record!(reason: reason, cause: cause)
    end

    # Serialized causal chain for cancelled Workflows (nil for any other
    # state). Pre-attribution records render `attribution_available: false`.
    def self.payload_for(workflow, include_cascade: true)
      return unless workflow.state == "cancelled"

      new(workflow).payload(include_cascade: include_cascade)
    end

    def self.step_payload(step)
      raw = step.details.to_h[STEP_DETAIL_KEY]
      raw.is_a?(Hash) ? raw : nil
    end

    # A Run's immediate causal parent is its Step; the Step reference carries
    # the event ids and the Workflow that was the Step's own parent.
    def self.run_payload(run, step: run.step)
      return unless run.state == "cancelled"

      ref = step && step_payload(step)
      return unavailable unless ref

      ref.merge("attribution_available" => true, "parent" => { "type" => "step", "id" => step.id },
                "step_parent" => ref["parent"])
    end

    def self.unavailable
      { "attribution_available" => false }
    end

    def initialize(workflow)
      @workflow = workflow
    end

    def record!(reason:, cause: nil)
      existing = workflow.artifacts.to_h[ARTIFACT_KEY]
      return existing if existing.is_a?(Hash) && existing["event_id"].present?

      cause = normalize_cause(cause || Current.cancellation_cause)
      ambient_parent = Current.cancellation_parent_workflow_id
      if ambient_parent && ambient_parent != workflow.id
        cause = { "kind" => nil, "initiator_class" => "Workflow", "initiator_id" => ambient_parent,
                  "control_path" => "cascade" }.merge(cause.compact)
        cause["parent_workflow_id"] ||= ambient_parent
      end
      event = cause.present? ? build_event(reason, cause) : unattributed_event(reason)
      workflow.artifacts = workflow.artifacts.to_h.merge(ARTIFACT_KEY => event)
      instrument(event)
      event
    end

    # Reference stamped on cleaned-up Steps; always derived from the
    # workflow's own recorded attribution.
    def step_reference
      event = workflow.artifacts.to_h[ARTIFACT_KEY]
      return unless event.is_a?(Hash)

      event.slice("event_id", "root_event_id", "cascade_id", "root_workflow_id", "kind", "attributed").merge(
        "parent" => { "type" => "workflow", "id" => workflow.id }
      )
    end

    def payload(include_cascade: true)
      event = workflow.artifacts.to_h[ARTIFACT_KEY]
      return self.class.unavailable unless event.is_a?(Hash) && event["event_id"].present?

      root_id = event["root_workflow_id"]
      root_event = root_id == workflow.id ? event : root_event_for(root_id) || event
      event.merge(
        "attribution_available" => true,
        "root" => root_id == workflow.id,
        "root_event" => root_id == workflow.id ? nil : root_event,
        "descendants" => (include_cascade && root_id == workflow.id ? descendants(event["cascade_id"]) : nil),
        "replacement_workflow_ids" => replacement_ids(root_event)
      ).compact
    end

    # Records the replacement Workflow on an already-recorded supersession
    # once it is known. Only fills a missing link; never alters the cause.
    def self.link_replacement!(cancelled, replacement)
      event = cancelled.artifacts.to_h[ARTIFACT_KEY]
      return false unless event.is_a?(Hash) && event["kind"] == "supersession"
      return false if event.dig("source", "replacement_workflow_id").present?

      source = event["source"].to_h.merge("replacement_workflow_id" => replacement.id)
      cancelled.update_columns(artifacts: cancelled.artifacts.to_h.merge(ARTIFACT_KEY => event.merge("source" => source)))
      true
    end

    private

    attr_reader :workflow

    def normalize_cause(cause)
      return {} if cause.blank?

      cause.to_h.stringify_keys.slice(*CAUSE_KEYS)
    end

    def build_event(reason, cause)
      parent = parent_attribution(cause)
      root = parent || {}
      cascade = root["cascade_id"].presence || SecureRandom.uuid
      event_id = SecureRandom.uuid
      {
        "event_id" => event_id,
        "root_event_id" => root["root_event_id"].presence || root["event_id"].presence || event_id,
        "cascade_id" => cascade,
        "root_workflow_id" => root["root_workflow_id"] || workflow.id,
        "parent_workflow_id" => cause["parent_workflow_id"]&.to_i,
        "parent_event_id" => root["event_id"],
        "occurred_at" => Time.current.iso8601(6),
        "kind" => cause["kind"].presence || self.class.kind_for(reason),
        "initiator_class" => cause["initiator_class"].presence || UNKNOWN_INITIATOR,
        "initiator_id" => cause["initiator_id"]&.to_s,
        "control_path" => cause["control_path"].to_s.presence,
        "reason" => redact(cause["reason"].presence || reason),
        "source" => sanitize_source(cause["source"]),
        "attributed" => true
      }.compact
    end

    def unattributed_event(reason)
      {
        "event_id" => (event_id = SecureRandom.uuid),
        "root_event_id" => event_id,
        "cascade_id" => SecureRandom.uuid,
        "root_workflow_id" => workflow.id,
        "occurred_at" => Time.current.iso8601(6),
        "kind" => UNATTRIBUTED_KIND,
        "initiator_class" => UNKNOWN_INITIATOR,
        "reason" => redact(reason),
        "source" => {},
        "attributed" => false
      }
    end

    # A cause that names its parent Workflow inherits that Workflow's event,
    # cascade and root, so the whole cascade shares one root event.
    def parent_attribution(cause)
      parent_id = cause["parent_workflow_id"]
      return unless parent_id.present? && parent_id.to_i != workflow.id

      event = Current.cancellation_parent_event if Current.cancellation_parent_workflow_id == parent_id.to_i
      event ||= Workflow.find_by(id: parent_id)&.artifacts.to_h&.[](ARTIFACT_KEY)
      event if event.is_a?(Hash) && event["event_id"].present?
    end

    def root_event_for(root_id)
      event = Workflow.find_by(id: root_id)&.artifacts.to_h&.[](ARTIFACT_KEY)
      event if event.is_a?(Hash)
    end

    # Bounded by id (descendants are always newer than the root) and state so
    # the cascade lookup never scans the whole workflows table.
    def descendants(cascade_id)
      root_id = workflow.artifacts.to_h.dig(ARTIFACT_KEY, "root_workflow_id")
      return [] if cascade_id.blank? || root_id.blank?

      Workflow.where(state: "cancelled").where("id >= ?", root_id).where.not(id: workflow.id)
              .where("artifacts LIKE ?", "%#{cascade_id}%").order(:id).filter_map do |candidate|
        ref = candidate.artifacts.to_h[ARTIFACT_KEY]
        next unless ref.is_a?(Hash) && ref["cascade_id"] == cascade_id

        { "workflow_id" => candidate.id, "job_id" => candidate.job_id, "state" => candidate.state,
          "parent_workflow_id" => ref["parent_workflow_id"], "reason" => ref["reason"] }
      end
    end

    def replacement_ids(root_event)
      ids = Array(root_event.to_h.dig("source", "replacement_workflow_id"))
      ids.compact.map(&:to_i)
    end

    def sanitize_source(source)
      return {} unless source.is_a?(Hash)

      source.to_h.stringify_keys.each_with_object({}) do |(key, value), safe|
        next unless key.match?(SOURCE_ID_KEY)
        safe[key] = sanitize_source_value(value)
        safe.delete(key) if safe[key].nil?
      end
    end

    def sanitize_source_value(value)
      case value
      when Numeric then value
      when String then redact(value)
      when Array then value.first(50).filter_map { |item| sanitize_source_value(item) unless item.is_a?(Array) || item.is_a?(Hash) }
      end
    end

    def redact(text)
      CommandRedactor.redact(text.to_s)
    end

    def instrument(event)
      Syrus::Metrics.counter(:syrus_workflow_cancellations_total)
        .increment(tags: { kind: event["kind"] })
      return if event["attributed"]

      Syrus::Metrics.counter(:syrus_workflow_cancellations_unattributed_total).increment(tags: { kind: event["kind"] })
      Rails.logger.error(
        "[WorkflowCancellation] invariant violation: unattributed cancellation " \
        "event=unattributed_workflow_cancellation workflow_id=#{workflow.id} job_id=#{workflow.job_id} " \
        "event_id=#{event['event_id']} reason=#{event['reason']}"
      )
    end
  end
end
