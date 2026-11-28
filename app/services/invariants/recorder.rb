module Invariants
  # Persists a full evaluation as InvariantViolation episodes: opens a row for
  # each newly seen fingerprint, refreshes rows that are still violated, and
  # resolves open rows the evaluation no longer reports. This is the only
  # writing part of the monitor; the invariants themselves stay pure.
  #
  # Only invariants that evaluated cleanly resolve rows: an invariant that
  # raised says nothing about whether its earlier violations went away.
  class Recorder
    Outcome = Data.define(:opened, :refreshed, :resolved)

    def self.record!(report) = new(report).record!

    def initialize(report)
      raise ArgumentError, "only a full-scope evaluation can be recorded" unless report.scope.all?

      @report = report
    end

    def record!
      now = report.evaluated_at
      opened = []
      refreshed = []
      resolved = []

      InvariantViolation.transaction do
        open_by_fingerprint = InvariantViolation.open.where(invariant_key: report.results.map(&:key)).index_by(&:fingerprint)

        report.violations.each do |violation|
          record = open_by_fingerprint.delete(violation.fingerprint)
          if record
            record.update!(attributes_for(violation).merge(last_detected_at: now, detection_count: record.detection_count + 1))
            refreshed << record
          else
            opened << InvariantViolation.create!(attributes_for(violation).merge(first_detected_at: now, last_detected_at: now))
          end
        end

        cleanly_evaluated = report.results.reject(&:error).map(&:key)
        open_by_fingerprint.each_value do |record|
          next unless cleanly_evaluated.include?(record.invariant_key)

          record.update!(resolved_at: now)
          resolved << record
        end
      end

      Outcome.new(opened: opened, refreshed: refreshed, resolved: resolved)
    end

    private

    attr_reader :report

    def attributes_for(violation)
      {
        invariant_key: violation.invariant,
        fingerprint: violation.fingerprint,
        severity: violation.severity,
        subject_type: violation.subject_type,
        subject_id: violation.subject_id,
        message_params: violation.message_params,
        details: violation.details,
        affected_ids: violation.affected_ids,
        violating_since: violation.since
      }
    end
  end
end
