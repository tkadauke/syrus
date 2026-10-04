module Workflows
  SKIP_PREPARE_LABEL = "syrus-skip-prepare".freeze
  TRACK_LABEL_PREFIX = "syrus-track-".freeze
  # Files the issue as a read-only investigation (no PR expected) instead of
  # an implementation Job. A label rather than a marker in the issue body on
  # purpose: this decides which workflow chain runs, and that is exactly the
  # kind of operational decision that should come from structured, operator-set
  # metadata rather than from matching prose.
  INVESTIGATION_LABEL = "syrus-investigation".freeze

  def self.label_names(labels)
    Array(labels).map do |label|
      if label.respond_to?(:name)
        label.name
      elsif label.is_a?(Hash)
        label[:name] || label["name"] || label.to_s
      else
        label.to_s
      end
    end
  end

  # A `syrus-track-<name>` label selects `Job#delivery_track` at issue
  # ingest time, e.g. `syrus-track-hotfix` -> "hotfix". Returns nil when no
  # such label is present, or when the part after the prefix is blank —
  # nil means "use the policy default" (see `DeliveryPolicy#track_for`).
  def self.track_label_value(labels)
    label_names(labels).find { |name| name.start_with?(TRACK_LABEL_PREFIX) }
                        &.delete_prefix(TRACK_LABEL_PREFIX)
                        &.presence
  end

  def self.for(trigger_kind:)
    Workflow::TriggerKind.template_for(trigger_kind)
  rescue ArgumentError
    raise ArgumentError, "no workflow template for trigger_kind=#{trigger_kind.inspect}"
  end
end
