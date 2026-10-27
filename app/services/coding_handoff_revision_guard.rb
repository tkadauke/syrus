class CodingHandoffRevisionGuard
  LATEST_FIX_ARTIFACT = "latest_coding_handoff_fix".freeze
  PUBLICATION_PROVENANCE_ARTIFACT = "coding_handoff_publication_provenance".freeze
  REBASE_RESULT_ARTIFACT = "auto_rebase_result".freeze
  CONFLICT_REBASE_REASON = "conflict".freeze

  class MissingLatestFix < StandardError; end

  def self.record_fix!(...) = new(...).record_fix!
  def self.verify_latest_fix!(...) = new(...).verify_latest_fix!

  def initialize(workflow: nil, job: nil, run: nil, git: GitRunner.new, workspace_path: nil, base_ref: nil, log: nil)
    @workflow = workflow
    @job = job || workflow&.job
    @run = run
    @git = git
    @workspace_path = workspace_path
    @base_ref = base_ref
    @log = log || ->(_message, **) { }
  end

  def record_fix!
    diff = run.step_agent_diff.to_s
    patch_id = patch_id_for(diff)
    return if patch_id.blank?

    workflow.set_artifact!(LATEST_FIX_ARTIFACT, {
      "workflow_id" => workflow.id,
      "step_id" => run.step_id,
      "run_id" => run.id,
      "iteration" => run.step.iteration,
      "base_sha" => run.base_sha,
      "head_sha" => run.head_sha,
      "patch_id" => patch_id,
      "recorded_at" => Time.current.iso8601,
      "visual_review" => visual_review_state_after(run.step, source_workflow: workflow)
    }.compact)
  end

  def verify_latest_fix!
    fix = latest_fix
    return if fix.blank?

    current_head = git.run("rev-parse", "HEAD", chdir: workspace_path.to_s).strip
    present = patch_ids_on_branch.include?(fix.fetch("patch_id"))
    rewritten = !present && rewritten_by_conflict_resolution?(fix)
    provenance = {
      "latest_fix" => fix,
      "branch_head_sha" => current_head,
      "base_ref" => base_ref,
      "verified" => present || rewritten,
      "verified_via" => (present ? "patch_id" : ("conflict_resolution" if rewritten)),
      "visual_review" => visual_review_state_for(fix),
      "checked_at" => Time.current.iso8601
    }.compact
    workflow&.set_artifact!(PUBLICATION_PROVENANCE_ARTIFACT, provenance)

    return if present
    if rewritten
      log.call(
        "[coding_handoff] latest coding_handoff_fix Run ##{fix['run_id']} (#{fix['head_sha']}) was rewritten while " \
        "resolving a rebase conflict, so its patch id cannot match; the pre-rebase head contained it and the rebase " \
        "ran to completion",
        kind: "system"
      )
      return
    end

    raise MissingLatestFix,
      "latest coding_handoff_fix Run ##{fix['run_id']} (#{fix['head_sha']}) is not present in final branch HEAD #{current_head}"
  end

  private

  attr_reader :workflow, :job, :run, :git, :workspace_path, :base_ref, :log

  def latest_fix
    @latest_fix ||= begin
      workflows = if Workflows::CodingHandoff.revision_guard_applies?(workflow)
        [ workflow ]
      else
        Workflows::CodingHandoff.revision_guard_workflows_for(job)
      end

      workflows.filter_map { |candidate| candidate.artifact(LATEST_FIX_ARTIFACT) }
        .select { |entry| entry.is_a?(Hash) && entry["patch_id"].present? }
        .max_by { |entry| [ entry["recorded_at"].to_s, entry["run_id"].to_i ] }
    end
  end

  # A patch id cannot survive a conflict resolution. Resolving a conflict is
  # what changes the content, so the rebased commit legitimately carries a
  # different patch id from the one recorded before the rebase -- and demanding
  # identity made this guard unsatisfiable for precisely the case it most needed
  # to handle, a branch far enough behind its base that rebasing it conflicts.
  # One pull request filed 64 failed rebase workflows over three weeks against
  # this check, each one spending an agent invocation to arrive at the same
  # refusal, because the fix it was protecting was the branch tip the rebase had
  # to rewrite.
  #
  # What remains verifiable is that the rebase carried the fix forward rather
  # than dropping it: the pre-rebase head contained the fix, and the rebase ran
  # to completion (this runs from the publish step, after the resolution
  # succeeded). That is the question the guard was always asking; patch-id
  # identity was only ever a proxy for it, and a proxy that is unavailable here.
  def rewritten_by_conflict_resolution?(fix)
    result = workflow&.artifact(REBASE_RESULT_ARTIFACT)
    return false unless result.is_a?(Hash)
    return false unless result["reason"].to_s == CONFLICT_REBASE_REASON

    pre_sha = result["pre_sha"].to_s.presence
    fix_head = fix["head_sha"].to_s.presence
    return false if pre_sha.blank? || fix_head.blank?

    contained_in?(fix_head, pre_sha)
  end

  # "Cannot tell" is not "no", but it is also not evidence, so it reads as
  # false and the refusal stands -- with a log line saying which happened, so
  # an unverifiable object does not look like a dropped fix.
  def contained_in?(candidate, descendant)
    git.run("merge-base", "--is-ancestor", candidate, descendant, chdir: workspace_path.to_s)
    true
  rescue GitRunner::GitError => e
    log.call(
      "[coding_handoff] could not establish whether #{candidate} is contained in pre-rebase head #{descendant}: #{e.message}",
      kind: "system"
    )
    false
  end

  def patch_ids_on_branch
    range = base_ref.present? ? "#{base_ref}..HEAD" : "HEAD"
    output = git.run("log", "--format=email", "--patch", range, chdir: workspace_path.to_s)
    patch_ids_for(output)
  rescue GitRunner::GitError => e
    log.call("[coding_handoff] could not compute branch patch ids for #{range}: #{e.message}", kind: "system")
    []
  end

  def patch_id_for(diff)
    patch_ids_for(diff).first
  end

  def patch_ids_for(diff)
    return [] if diff.blank?

    output = git.run("patch-id", "--stable", stdin_data: diff.to_s, workflow: workflow)

    output.lines.filter_map { |line| line.split(/\s+/).first.presence }
  end

  def visual_review_state_for(fix)
    step = Step.find_by(id: fix["step_id"])
    return fix["visual_review"] if step.blank?

    visual_review_state_after(step, source_workflow: step.workflow)
  end

  def visual_review_entries_after(fix_step, source_workflow:)
    visual_steps = source_workflow.steps.where(kind: "visual_review").index_by(&:id)
    Array(source_workflow.artifact("visual_review_iterations")).select do |entry|
      next false unless entry.is_a?(Hash)

      visual_step = visual_steps[entry["step_id"].to_i]
      visual_step && visual_step.position > fix_step.position
    end
  end

  def visual_review_state_after(fix_step, source_workflow:)
    entries = visual_review_entries_after(fix_step, source_workflow: source_workflow)
    latest = entries.last
    {
      "status" => visual_review_status(latest),
      "step_id" => latest&.dig("step_id"),
      "run_id" => latest&.dig("run_id"),
      "verdict" => latest&.dig("verdict"),
      "checked_after_fix" => latest.present?
    }.compact
  end

  def visual_review_status(entry)
    return "not_reviewed_after_latest_fix" if entry.blank?

    verdict = entry["verdict"].to_s
    return "verified_after_latest_fix" if verdict == "approved" || verdict == "skipped"

    "failed_after_latest_fix"
  end
end
