# A request's identity, independent of which door it came through
# (workflow-engine-v3 C4).
#
# `Job#external_ref` exists but is per-source and unqualified: the GitHub input
# source stores the bare issue number, and lookups only work because they scope
# by `input_source_id` as well. With input-source plugins, PR intake, chat
# proposals and bug reports, one request can enter through several doors, and
# "42" from two of them is two different things.
#
# A source ref is `"<kind>:<qualifier>"` -- `"github:acme/widgets#42"` --
# which is comparable across doors without anyone having to remember to also
# compare the source. The plan's point is that this is cheap now and awkward
# later; it is deliberately a derived string rather than a new join.
module SourceRef
  SEPARATOR = ":".freeze

  def self.build(kind:, qualifier:)
    kind = kind.to_s.strip
    qualifier = qualifier.to_s.strip
    return nil if kind.empty? || qualifier.empty?

    "#{kind}#{SEPARATOR}#{qualifier}"
  end

  def self.parse(ref)
    kind, qualifier = ref.to_s.split(SEPARATOR, 2)
    return nil if kind.blank? || qualifier.blank?

    { kind: kind, qualifier: qualifier }
  end

  # The ref for a Job, derived from whichever door it actually came through.
  # Returns nil when a Job has no natural external identity -- a `direct` Job
  # someone typed a prompt into is not the same request as anything else.
  def self.for_job(job)
    return nil unless job

    if job.issue_number.present? && job.repository
      return build(kind: source_kind_for(job), qualifier: "#{job.repository.slug}##{job.issue_number}")
    end

    if job.external_pr_number.present? && job.repository
      return build(kind: "pr", qualifier: "#{job.repository.slug}##{job.external_pr_number}")
    end

    return build(kind: "scheduled_task", qualifier: job.scheduled_task_id.to_s) if job.scheduled_task_id.present?

    nil
  end

  # The input source names the door. InputSource is an STI model, so its type
  # is the kind ("InputSources::Github" -> "github"). Without one, an
  # issue-backed Job came through GitHub polling, which is the only other door
  # that produces one.
  def self.source_kind_for(job)
    type = job.input_source&.type
    return "github" if type.blank?

    type.to_s.demodulize.underscore
  end
end
