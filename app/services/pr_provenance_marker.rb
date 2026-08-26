# Structured Syrus-provenance metadata stamped into a PR body by
# Syrus-authored ref-movement workflows (`Steps::PromotionPublish`,
# `Steps::UpstreamExportPublish`) and read back by `PrProvenanceClassifier`
# when a maintainer's Syrus instance later ingests that PR
# (`PollExternalOpenPrsJob`). Per
# docs/plans/delivery-tracks-and-promotion.md Story 10: "structured Syrus
# metadata first, heuristic fallback second."
#
# An HTML comment, invisible in GitHub's rendered PR body — same idiom as
# `PrStackFooter`/`ReviewPlanFormatter`/`PrCostFooter` markers, chosen over a
# visible line so it doesn't clutter a PR body meant for human review.
# Commit trailers are a documented alternative structured-metadata location
# in the plan; not implemented here — the PR body marker alone is enough to
# make every real ref-movement PR self-describing, and heuristics (branch
# naming, known-fork matching) cover the rest.
class PrProvenanceMarker
  START = "<!-- syrus-provenance:".freeze
  END_ = " -->".freeze

  # Only the kinds a Syrus workflow actually stamps itself. `manual_hotfix`
  # and `external_unknown` are never stamped — they're exactly the
  # classifications for PRs Syrus did *not* author.
  STAMPABLE_KINDS = %w[syrus_job_export syrus_promotion].freeze

  def self.stamp(kind:, job:)
    raise ArgumentError, "unknown provenance kind #{kind.inspect}" unless STAMPABLE_KINDS.include?(kind.to_s)

    "#{START}kind=#{kind};job_id=#{job.id}#{END_}"
  end

  def self.parse(body)
    return nil if body.blank?

    match = body.to_s.match(/#{Regexp.escape(START)}(.*?)#{Regexp.escape(END_)}/m)
    return nil unless match

    fields = match[1].to_s.split(";").each_with_object({}) do |pair, hash|
      key, value = pair.split("=", 2)
      hash[key.to_s.strip] = value.to_s.strip if key.present?
    end
    return nil if fields["kind"].blank?

    fields
  end
end
