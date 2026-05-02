module JobsHelper
  STATE_STYLES = {
    "queued"    => "bg-gray-100 text-gray-700",
    "running"   => "bg-blue-100 text-blue-700",
    "succeeded" => "bg-green-100 text-green-700",
    "failed"    => "bg-red-100 text-red-700",
    "cancelled" => "bg-amber-100 text-amber-700",
    "open"      => "bg-emerald-100 text-emerald-700",
    "closed"    => "bg-gray-200 text-gray-800",
    "pending"   => "bg-gray-100 text-gray-700"
  }.freeze

  TRIGGER_STYLES = {
    "initial"     => "bg-purple-100 text-purple-700",
    "pr_comment"  => "bg-cyan-100 text-cyan-700",
    "ci_failure"  => "bg-red-100 text-red-700",
    "replay"      => "bg-amber-100 text-amber-700",
    "manual"      => "bg-gray-100 text-gray-700"
  }.freeze

  def state_pill(state, classes: nil)
    style = STATE_STYLES[state.to_s] || "bg-gray-100 text-gray-700"

    if state.to_s == "running"
      spinner = content_tag(:svg, xmlns: "http://www.w3.org/2000/svg", fill: "none", viewBox: "0 0 24 24", class: "animate-spin h-3 w-3") do
        content_tag(:circle, "", cx: "12", cy: "12", r: "10", stroke: "currentColor", "stroke-width" => "4", class: "opacity-25") +
        content_tag(:path, "", fill: "currentColor", d: "M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z", class: "opacity-75")
      end
      content_tag(:span, class: "inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium #{style} #{classes}") do
        safe_join([ state.to_s, spinner ])
      end
    else
      tag.span(state, class: "inline-block px-2 py-0.5 rounded text-xs font-medium #{style} #{classes}")
    end
  end

  def trigger_pill(trigger_kind)
    style = TRIGGER_STYLES[trigger_kind.to_s] || "bg-gray-100 text-gray-700"
    tag.span(trigger_kind, class: "inline-block px-2 py-0.5 rounded text-xs font-medium #{style}")
  end

  # The most useful one-word summary for a Job in a list view: closure
  # state if closed, otherwise the latest run's state, otherwise "pending".
  def job_summary_state(job)
    return "closed" if job.closed?
    job.current_run&.state || "pending"
  end

  def job_pr_url(job)
    return nil unless job.pr_number
    "https://github.com/#{job.repository.slug}/pull/#{job.pr_number}"
  end

  def job_issue_url(job)
    "https://github.com/#{job.repository.slug}/issues/#{job.issue_number}"
  end
end
