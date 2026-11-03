module PushProtection
  # Durable record of a push-protection incident and of the last commit GitHub
  # is known to have accepted for the Job's branch (the "clean anchor").
  #
  # Stored as a single workflow artifact so no schema change is needed. A new
  # Workflow on the same Job seeds from the newest sibling's ledger, which
  # keeps the lineage (job -> workflows -> anchor) intact across attempts.
  #
  # Only sanitized data lives here: secret types, paths, line numbers and SHAs.
  class Ledger
    ARTIFACT_KEY = "push_protection".freeze
    MAX_REPAIR_ATTEMPTS = 2 # one repair plus one retry with precise feedback

    # Statuses, in the order an incident normally moves through them.
    REPAIRING = "repairing".freeze
    OPERATOR_REVIEW = "operator_review".freeze # bounded limit hit or unrepairable
    UPSTREAM = "upstream_contaminated".freeze  # finding is in the accepted/shared history
    QUARANTINED = "quarantined".freeze         # shared/synthesized ref routed to its origin
    RESOLVED = "resolved".freeze
    ACTIVE_STATUSES = [ REPAIRING ].freeze

    def self.for(workflow) = new(workflow)

    def initialize(workflow)
      @workflow = workflow
    end

    def data
      own = workflow.artifact(ARTIFACT_KEY)
      return own if own.is_a?(Hash)

      sibling_data
    end

    def clean_anchor = data["clean_anchor"].presence
    def status = data["status"]
    def attempts = data["attempts"].to_i
    def rejected_shas = Array(data["rejected_shas"])
    def evidence = data["evidence"].to_h

    # While a repair is in flight, ordinary checkpoint publication would
    # republish the rejected ancestry to GitHub, so it is suppressed.
    def repair_active? = ACTIVE_STATUSES.include?(status)

    def rejected?(sha) = sha.present? && rejected_shas.include?(sha)

    def attempts_exhausted? = attempts >= MAX_REPAIR_ATTEMPTS

    # Advance the anchor only after GitHub accepted the pushed SHA.
    def record_accepted!(sha)
      return if sha.blank?

      write!(data.merge("clean_anchor" => sha, "accepted_at" => Time.current.iso8601))
    end

    def seed_anchor!(sha)
      return if clean_anchor.present? || sha.blank?

      write!(data.merge("clean_anchor" => sha))
    end

    def record_rejection!(sha:, findings:, ref:, status:, extra: {})
      current = data
      write!(current.merge(
        "status" => status,
        "ref" => ref,
        "lineage" => lineage,
        "rejected_shas" => (Array(current["rejected_shas"]) + [ sha ]).compact.uniq,
        "attempts" => current["attempts"].to_i,
        "evidence" => {
          "findings" => findings.map(&:to_h),
          "detected_at" => Time.current.iso8601
        },
        "contract_violations" => []
      ).merge(extra.stringify_keys))
    end

    def update!(attrs)
      write!(data.merge(attrs.stringify_keys))
    end

    def increment_attempts!(violations: [])
      update!("attempts" => attempts + 1, "contract_violations" => violations)
    end

    def lineage
      { "job_id" => workflow.job_id, "workflow_id" => workflow.id, "branch" => workflow.job.branch_name }
    end

    private

    attr_reader :workflow

    def write!(hash)
      workflow.set_artifact!(ARTIFACT_KEY, hash)
      hash
    end

    def sibling_data
      sibling = workflow.job.workflows.where.not(id: workflow.id).reorder(id: :desc).detect do |w|
        w.artifact(ARTIFACT_KEY).is_a?(Hash)
      end
      sibling ? sibling.artifact(ARTIFACT_KEY).to_h : {}
    end
  end
end
