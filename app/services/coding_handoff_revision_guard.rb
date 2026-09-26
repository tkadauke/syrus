require "open3"

class CodingHandoffRevisionGuard
  LATEST_FIX_ARTIFACT = "latest_coding_handoff_fix".freeze
  PUBLICATION_PROVENANCE_ARTIFACT = "coding_handoff_publication_provenance".freeze

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
    provenance = {
      "latest_fix" => fix,
      "branch_head_sha" => current_head,
      "base_ref" => base_ref,
      "verified" => present,
      "visual_review" => visual_review_state_for(fix),
      "checked_at" => Time.current.iso8601
    }.compact
    workflow&.set_artifact!(PUBLICATION_PROVENANCE_ARTIFACT, provenance)

    return if present

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

    output, status = Open3.capture2e("git", "patch-id", "--stable", stdin_data: diff.to_s)
    raise GitRunner::GitError.new([ "patch-id", "--stable" ], status.exitstatus || -1, output) unless status.success?

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
