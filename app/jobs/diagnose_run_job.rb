require "open3"

# Captures a point-in-time health snapshot of an active Run and persists
# it as a RunHealthSnapshot. Triggered by the operator's "Diagnose" button;
# enqueued immediately and returns; React fetches the result through the app API.
#
# All signal capture is best-effort: if a subsystem is unreachable (SQ
# tables absent in test, /proc not on this OS, worktree already cleaned up),
# the relevant fields stay nil and the view renders them as "unavailable."
# A failed capture never crashes the job — it just produces a partial snapshot.
class DiagnoseRunJob < ApplicationJob
  queue_as :default

  # One diagnostic at a time per Run so rapid button-clicks don't pile up.
  limits_concurrency to: 1, key: ->(run_id) { "diagnose:#{run_id}" }

  # Heartbeat thresholds for health-status colour-coding.
  WARNING_HEARTBEAT  = 5.minutes
  CRITICAL_HEARTBEAT = Run::STALE_HEARTBEAT_THRESHOLD  # 30 min
  AGENT_PROCESS_NAMES = {
    "claude" => "claude",
    "codex" => "codex"
  }.freeze

  def perform(run_id)
    run = Run.includes(:job, :step, job_logs: []).find_by(id: run_id)
    return unless run

    snapshot = RunHealthSnapshot.new(run: run)
    capture_db_signals(snapshot, run)
    capture_sq_signals(snapshot, run)
    capture_process_signals(snapshot, run)
    snapshot.health_status = compute_health_status(snapshot, run)
    snapshot.hint          = compute_hint(snapshot, run)
    snapshot.save!
  end

  private

  # ── DB-level signals ────────────────────────────────────────────────────

  def capture_db_signals(snapshot, run)
    snapshot.run_state = run.state

    hb = run.last_heartbeat_at
    snapshot.last_heartbeat_at     = hb
    snapshot.heartbeat_age_seconds = hb ? (Time.current - hb).to_i : nil

    last_log = run.job_logs.last
    snapshot.last_log_at    = last_log&.created_at
    snapshot.log_count      = run.job_logs.size
    snapshot.last_log_preview = last_log&.chunk&.first(200)

    snapshot.agent_turns    = run.agent_turns
    snapshot.agent_outcome  = run.agent_outcome
    snapshot.agent_diff_bytes = run.agent_diff&.bytesize
    snapshot.head_sha       = run.head_sha
  end

  # ── SolidQueue signals ───────────────────────────────────────────────────

  def capture_sq_signals(snapshot, run)
    sq_job = SolidQueue::Job
      .where(class_name: "RunJob")
      .where("arguments LIKE ?", "%\"#{run.id}\"%")
      .includes(:claimed_execution, :failed_execution)
      .order(id: :desc)
      .first

    if sq_job.nil?
      snapshot.sq_job_state = "missing"
    elsif (fe = sq_job.failed_execution)
      snapshot.sq_job_state = "failed"
      error = fe.error
      if error.is_a?(Hash)
        snapshot.sq_error_class     = error["exception_class"]
        snapshot.sq_error_message   = error["message"]&.first(2_000)
        snapshot.sq_error_backtrace = Array(error["backtrace"]).first(10).join("\n")
      end
    elsif sq_job.claimed_execution
      snapshot.sq_job_state = "claimed"
    elsif sq_job.finished_at.present?
      snapshot.sq_job_state = "finished"
    else
      snapshot.sq_job_state = "ready"
    end
  rescue ActiveRecord::StatementInvalid => e
    # SolidQueue tables not reachable (single-database test setup, etc.).
    Rails.logger.debug("[DiagnoseRunJob] SolidQueue tables unreachable (#{e.class}); sq_job_state left nil")
  end

  # ── Process-level signals ────────────────────────────────────────────────

  def capture_process_signals(snapshot, run)
    workflow = run.step&.workflow
    unless workflow
      Rails.logger.debug("[DiagnoseRunJob] Run ##{run.id} has no step/workflow — skipping process signals")
      return
    end

    # If the owning worker pod is known but no longer live, this job may be
    # executing on a different pod — the workspace lives on the owning pod's
    # volume, so File.directory? would return a false negative. Leave
    # worktree_exists and claude_process_running as nil (unavailable) rather
    # than asserting the workspace is gone and triggering a destructive hint.
    owning_host = workflow.worker_hostname
    if owning_host.present? && !InstanceVersion.worker_live?(owning_host)
      Rails.logger.debug("[DiagnoseRunJob] Run ##{run.id}: owning host #{owning_host} not live — filesystem signals unavailable")
      return
    end

    workspace_path = WorkflowWorkspace.path_for(workflow).to_s
    snapshot.worktree_exists = File.directory?(workspace_path)

    if snapshot.worktree_exists
      base = "origin/#{run.job.repository.default_branch}"

      snapshot.worktree_git_status     = safe_git("status", "--porcelain", chdir: workspace_path)
      snapshot.worktree_recent_commits  = safe_git("log", "--oneline", "--max-count=5",
                                                    "#{base}..HEAD", chdir: workspace_path)

      branch = run.job.branch_name
      if branch.present?
        ref_out = safe_git("rev-parse", "--verify", "refs/remotes/origin/#{branch}",
                           chdir: workspace_path)
        # safe_git returns "(ExceptionClass: ...)" on failure; treat that as absent.
        snapshot.branch_on_origin = ref_out.present? && !ref_out.start_with?("(")
      end
    end

    running, info = check_agent_process(workspace_path, run.agent_provider)
    snapshot.claude_process_running = running
    snapshot.claude_process_info    = info
  rescue StandardError => e
    Rails.logger.warn("[DiagnoseRunJob] process signals failed for Run ##{run.id}: #{e.class}: #{e.message}")
  end

  # Check /proc for the expected agent process whose cwd matches the workspace.
  # Returns [true, info_string] | [false, nil] | [nil, nil] (unavailable).
  # Linux-only; degrades gracefully on other platforms.
  def check_agent_process(workspace_path, agent_provider)
    return [ nil, nil ] unless File.directory?("/proc")

    process_name = agent_process_name(agent_provider)
    return [ nil, "Unknown agent provider: #{agent_provider.inspect}" ] unless process_name

    Dir.glob("/proc/[0-9]*/cwd").each do |cwd_link|
      cwd = File.readlink(cwd_link) rescue next
      next unless cwd == workspace_path

      pid = File.dirname(cwd_link).split("/").last
      exe = File.readlink("/proc/#{pid}/exe") rescue nil
      cmdline = File.read("/proc/#{pid}/cmdline").gsub("\0", " ").strip rescue nil
      next unless agent_process_match?(process_name, exe, cmdline)

      return [ true, "PID #{pid}: #{cmdline&.first(200)}" ]
    end

    [ false, nil ]
  rescue StandardError => e
    [ nil, "(#{e.class}: #{e.message})" ]
  end

  def agent_process_name(agent_provider)
    AGENT_PROCESS_NAMES[agent_provider.to_s]
  end

  def agent_process_match?(process_name, exe, cmdline)
    File.basename(exe.to_s).include?(process_name) ||
      cmdline.to_s.split.first.to_s.include?(process_name)
  end

  # ── Assessment ───────────────────────────────────────────────────────────

  def compute_health_status(snapshot, run)
    return "critical" if snapshot.sq_job_state == "failed"
    return "critical" if snapshot.worktree_exists == false

    age = snapshot.heartbeat_age_seconds
    return "critical" if age && age > CRITICAL_HEARTBEAT.to_i

    if run.running?
      # Agent not found + heartbeat already stale past the warning threshold.
      if snapshot.claude_process_running == false && age && age > WARNING_HEARTBEAT.to_i
        return "critical"
      end
    end

    return "warning" if age && age > WARNING_HEARTBEAT.to_i
    return "warning" if snapshot.sq_job_state == "missing"

    "healthy"
  end

  def compute_hint(snapshot, run)
    age     = snapshot.heartbeat_age_seconds
    age_str = age ? "#{(age / 60.0).round(1)} min" : "unknown"

    if snapshot.sq_job_state == "failed"
      return "SolidQueue job failed (#{snapshot.sq_error_class}) — recommend Retry."
    end

    if snapshot.worktree_exists == false
      return "Workspace directory is gone — agent cannot make progress. Recommend Start over."
    end

    if age && age > CRITICAL_HEARTBEAT.to_i
      base = "Heartbeat #{age_str} stale (past #{CRITICAL_HEARTBEAT.inspect} threshold)"
      if snapshot.claude_process_running == false
        return "#{base} and agent process not found — recommend Retry."
      end
      return "#{base} — reaper will auto-cancel soon; use Cancel now to act first."
    end

    if age && age > WARNING_HEARTBEAT.to_i
      if snapshot.claude_process_running == false
        return "Heartbeat #{age_str} stale and agent process not found — may be stuck. Compare a second snapshot in a few minutes."
      end
      return "Heartbeat #{age_str} stale — agent is running but progress may be slow. Capture a second snapshot to confirm."
    end

    if snapshot.sq_job_state == "missing"
      return "SolidQueue job not found — Run may have been queued on a different worker or SQ inspection is unavailable."
    end

    "Run appears healthy — agent active and heartbeat fresh."
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  def safe_git(*args, chdir:)
    GitRunner.new.run(*args, chdir: chdir)
  rescue StandardError => e
    "(#{e.class}: #{e.message.to_s.first(300)})"
  end
end
