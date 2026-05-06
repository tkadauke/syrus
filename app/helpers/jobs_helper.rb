module JobsHelper
  STATE_STYLES = {
    "queued"    => "bg-gray-100 text-gray-700",
    "running"   => "bg-blue-100 text-blue-700",
    "succeeded" => "bg-green-100 text-green-700",
    "failed"    => "bg-red-100 text-red-700",
    "cancelled" => "bg-amber-100 text-amber-700",
    "open"      => "bg-emerald-100 text-emerald-700",
    "closed"    => "bg-gray-200 text-gray-800",
    "preempted" => "bg-violet-100 text-violet-700",
    "pending"   => "bg-gray-100 text-gray-700"
  }.freeze

  # Human-readable label per Step.kind. Keep these short — they
  # render in dashboard cells and in Job#show step headers next to
  # other compact metadata. Falls back to humanizing the kind for
  # any kind not yet enumerated here, so a new step type doesn't
  # blank out the UI.
  STEP_KIND_LABELS = {
    "prepare"         => "Prepare workspace",
    "implement"       => "Implement",
    "summarize"       => "Summarize",
    "pr_open"         => "Open PR",
    "respond"         => "Address feedback",
    "summarize_amend" => "Summarize",
    "push"            => "Push",
    "analyze_and_fix" => "Fix CI failures",
    "auto_rebase"     => "Auto-rebase",
    "agent_rebase"    => "Agent rebase",
    "force_push"      => "Force-push",
    "manual"          => "Manual"
  }.freeze

  def step_kind_label(kind)
    STEP_KIND_LABELS[kind.to_s] || kind.to_s.humanize
  end

  # Human-readable label per Workflow.trigger_kind. Used as the
  # workflow card title on Job#show, replacing the previous bare
  # "Workflow N" header that didn't say what the workflow was
  # actually doing. Falls back to humanizing the trigger kind so
  # an unknown kind doesn't blank the UI.
  WORKFLOW_LABELS = {
    "initial"    => "Initial implementation",
    "pr_comment" => "PR feedback",
    "ci_failure" => "CI failure",
    "rebase"     => "Rebase",
    "replay"     => "Replay",
    "manual"     => "Manual",
    "resume"     => "Resume"
  }.freeze

  def workflow_label(trigger_kind)
    WORKFLOW_LABELS[trigger_kind.to_s] || trigger_kind.to_s.humanize
  end

  TRIGGER_STYLES = {
    "initial"     => "bg-purple-100 text-purple-700",
    "pr_comment"  => "bg-cyan-100 text-cyan-700",
    "ci_failure"  => "bg-red-100 text-red-700",
    "retry"       => "bg-amber-100 text-amber-700",
    "manual"      => "bg-gray-100 text-gray-700",
    "rebase"      => "bg-teal-100 text-teal-700",
    "resume"      => "bg-fuchsia-100 text-fuchsia-700"
  }.freeze

  def state_pill(state, classes: nil)
    style = STATE_STYLES[state.to_s] || ApplicationHelper::PILL_FALLBACK_CLASSES

    # Running gets a custom shell because of the inline spinner — it
    # needs flex layout that the regular pill doesn't. All other
    # states fall through to the shared colored_pill primitive.
    if state.to_s == "running"
      spinner = content_tag(:svg, xmlns: "http://www.w3.org/2000/svg", fill: "none", viewBox: "0 0 24 24", class: "animate-spin h-3 w-3") do
        content_tag(:circle, "", cx: "12", cy: "12", r: "10", stroke: "currentColor", "stroke-width" => "4", class: "opacity-25") +
        content_tag(:path, "", fill: "currentColor", d: "M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z", class: "opacity-75")
      end
      content_tag(:span, class: "inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium #{style} #{classes}") do
        safe_join([ state.to_s, spinner ])
      end
    else
      colored_pill(state, classes: style, extra: classes)
    end
  end

  def trigger_pill(trigger_kind)
    colored_pill(trigger_kind, classes: TRIGGER_STYLES[trigger_kind.to_s] || ApplicationHelper::PILL_FALLBACK_CLASSES)
  end

  PRIORITY_STYLES = {
    "high"   => "bg-red-100 text-red-700",
    "medium" => "bg-gray-100 text-gray-700",
    "low"    => "bg-slate-100 text-slate-500"
  }.freeze

  def priority_pill(priority)
    colored_pill(priority, classes: PRIORITY_STYLES[priority.to_s] || ApplicationHelper::PILL_FALLBACK_CLASSES)
  end

  # The most useful one-word summary for a Job in a list view:
  # "preempted" beats "closed" when a Job was preempted by an external
  # PR — that's a more informative bucket than generic "closed."
  def job_summary_state(job)
    return "preempted" if job.closure_reason == "preempted"
    return "preempted" if job.closure_reason&.start_with?("external_pr_")
    return "closed" if job.closed?
    job.current_run&.state || "pending"
  end

  # Per-Job dashboard caption — when a workflow is in flight, show
  # what step it's on and what kicked it off. e.g. "currently:
  # Implement (workflow: initial)". Returns nil for jobs with no
  # active workflow so callers can omit the caption entirely.
  def current_step_caption(job)
    wf = job.workflows.where(state: "running").order(:created_at).last
    return nil unless wf
    step = wf.current_step
    return "currently: #{wf.trigger_kind_humanized}" unless step
    "currently: #{step_kind_label(step.kind)} (workflow: #{wf.trigger_kind_humanized})"
  end

  # Per-Workflow "current step" cell on the dashboard's Workflows
  # tab. Active workflow shows the step it's executing; finished
  # workflow shows the step it ended at and how many of N total
  # ran (cancelled / skipped via cancel_downstream! count toward N
  # but are reflected by an "of M" suffix when shorter).
  def workflow_step_caption(workflow)
    steps = workflow.steps.to_a
    return "—" if steps.empty?
    case workflow.state
    when "queued"
      "#{step_kind_label(steps.first.kind)} (1/#{steps.size})"
    when "running"
      cur = steps.find { |s| s.state == "running" } || steps.find { |s| s.state == "queued" } || steps.last
      "#{step_kind_label(cur.kind)} (#{steps.index(cur) + 1}/#{steps.size})"
    else
      last_executed = steps.reverse.find { |s| %w[succeeded failed].include?(s.state) } || steps.last
      "#{step_kind_label(last_executed.kind)} (#{steps.index(last_executed) + 1}/#{steps.size})"
    end
  end

  def job_pr_url(job)
    return nil unless job.pr_number
    "https://github.com/#{job.repository.slug}/pull/#{job.pr_number}"
  end

  def external_pr_url(job)
    return nil unless job.external_pr_number
    "https://github.com/#{job.repository.slug}/pull/#{job.external_pr_number}"
  end

  def job_issue_url(job)
    return nil if job.issue_number.blank?
    "https://github.com/#{job.repository.slug}/issues/#{job.issue_number}"
  end

  # Renders a per-Job source label — link to GitHub issue for issue
  # Jobs, link to ScheduledTask for cron Jobs. Used in dashboard +
  # job header so cron Jobs don't render a broken "#nil" link.
  def job_source_label_html(job)
    if job.cron?
      task = job.scheduled_task
      label = task ? "scheduled: #{task.name}" : "scheduled task ##{job.scheduled_task_id}"
      target = task ? scheduled_task_path(task) : nil
      target ? link_to(label, target, class: "text-blue-600 underline hover:no-underline") : label
    elsif job.adhoc?
      content_tag(:span, "ad hoc", class: "text-gray-600")
    else
      link_to "##{job.issue_number}", job_issue_url(job),
              target: "_blank", rel: "noopener",
              class: "text-blue-600 underline hover:no-underline"
    end
  end

  HEALTH_STATUS_STYLES = {
    "healthy"  => { text: "text-green-700",  bg: "bg-green-50",  border: "border-green-200" },
    "warning"  => { text: "text-amber-700",  bg: "bg-amber-50",  border: "border-amber-200" },
    "critical" => { text: "text-red-700",    bg: "bg-red-50",    border: "border-red-200"   }
  }.freeze

  # Three-way boolean signal cell: ✓ green / ✗ red / — gray-unavailable.
  def bool_signal(value)
    case value
    when true  then content_tag(:span, "✓", class: "text-green-600 font-medium")
    when false then content_tag(:span, "✗", class: "text-red-600 font-medium")
    else            content_tag(:span, "—", class: "text-gray-400")
    end
  end

  # Heartbeat age formatted + colour-coded by staleness thresholds.
  def heartbeat_signal(age_seconds)
    return content_tag(:span, "none", class: "text-gray-400") if age_seconds.nil?

    minutes = (age_seconds / 60.0).round(1)
    label   = "#{minutes} min ago"

    css = if age_seconds < DiagnoseRunJob::WARNING_HEARTBEAT.to_i
            "text-green-600"
    elsif age_seconds < DiagnoseRunJob::CRITICAL_HEARTBEAT.to_i
            "text-amber-600"
    else
            "text-red-600 font-medium"
    end

    content_tag(:span, label, class: css)
  end

  # SolidQueue job-state badge colour.
  def sq_state_signal(sq_job_state)
    return content_tag(:span, "—", class: "text-gray-400") if sq_job_state.nil?

    css = case sq_job_state
    when "claimed"  then "text-green-600"
    when "ready"    then "text-blue-600"
    when "finished" then "text-gray-500"
    when "failed"   then "text-red-600 font-medium"
    when "missing"  then "text-amber-600"
    else                 "text-gray-600"
    end

    content_tag(:span, sq_job_state, class: "font-mono #{css}")
  end

  MERGEABILITY_STYLES = {
    "mergeable"    => "bg-green-100 text-green-700",
    "needs rebase" => "bg-red-100 text-red-700",
    "checking…"    => "bg-gray-100 text-gray-500"
  }.freeze

  # Renders the last-known mergeability of a Job's PR as a pill.
  # PollRebaseJob caches `pr_mergeable` on the Job every 15 minutes;
  # the show page reads from that cache (no live GitHub call). Returns
  # nil when the Job has no PR — caller can ignore.
  def mergeable_pill(job)
    return nil unless job.pr_number.present? || job.external_pr_number.present?
    label = case job.pr_mergeable
    when true  then "mergeable"
    when false then "needs rebase"
    else            "checking…"
    end
    colored_pill(label, classes: MERGEABILITY_STYLES[label])
  end
end
