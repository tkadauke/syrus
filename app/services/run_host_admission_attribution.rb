# The latest host-admission decision recorded for a queued Run, read from the
# workflow's `run_host_admission` artifact (written by RunJob when admission
# defers a Run). Surfaced on the admin Run representation so a queued Run
# answers "what is holding this up?" without opening its Workflow.
#
# The artifact is workflow-scoped and outlives the Run it describes, so it is
# only attributed to a Run that is still queued and is the Run it names; a
# started or terminal Run reports nothing rather than a stale deferral.
module RunHostAdmissionAttribution
  module_function

  def for(run)
    return unless run&.queued?

    artifact = run.step&.workflow&.artifact("run_host_admission")
    return unless artifact.is_a?(Hash) && artifact["run_id"].to_i == run.id

    artifact
  end
end
