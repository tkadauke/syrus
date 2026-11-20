# A landing that cannot place a step on any live worker fails instead of
# parking in flight (parking surrendered the repository landing slot while the
# landing was still mid-way, so another landing could overlap it on a moved
# base). The failed landing keeps its approval (LandingFailureCode
# NO_CAPABLE_WORKER defers landing) and is held here: neither the landing queue
# nor the merge-train dispatcher re-launches it until a worker with the
# recorded capabilities is live again. formal/SyrusModel/LandingSlot.lean.
class LandingCapabilityHold
  ARTIFACT = "landing_capability_hold".freeze

  Hold = Data.define(:workflow, :queue, :requirements) do
    def released?
      RunQueueResolver.live_capable_worker?(queue: queue, requirements: requirements)
    end

    def reason
      "#{LandingFailureCode::NO_CAPABLE_WORKER}: waiting for a live worker with #{requirements.to_json} " \
        "(#{workflow.slug} could not place a step)"
    end
  end

  def self.record!(workflow, decision)
    workflow.set_artifact!(ARTIFACT, {
      "queue" => decision.queue_name,
      "requirements" => decision.requirements.to_h,
      "recorded_at" => Time.current.iso8601
    })
  end

  # The hold still in force for these Jobs: their latest landing attempt failed
  # on a capability hold and no capable worker is live yet. Any later landing
  # attempt supersedes it.
  def self.active_for(job_ids)
    ids = Array(job_ids).compact
    return nil if ids.empty?

    latest = Workflow
      .where(job_id: ids, trigger_kind: WorkDefinitions.landing_workflow_kinds)
      .order(id: :desc)
      .first
    return nil unless latest&.failed?

    raw = latest.artifact(ARTIFACT)
    return nil if raw.blank?

    hold = Hold.new(workflow: latest, queue: raw["queue"].to_s, requirements: raw["requirements"].to_h)
    hold.released? ? nil : hold
  end
end
