require "json"

class AgentEnvironmentSnapshot
  MAX_SCRIPT_LINES = 8
  MAX_GRADER_LINES = 8
  ELABORATION_EPIC_DESCRIPTION_BYTES = 4.kilobytes

  CHAT_TOOL_GROUPS = {
    "repository context" => %w[attach_repository repo_info read_repo_document list_repo_documents create_repo_document delete_repo_document],
    "live Syrus state" => %w[list_chats list_jobs read_job explain_stuck_job read_pr list_open_issues list_open_prs cancel_job close_job_successfully retry_job rebase_job reopen_job poll_job_feedback check_job_mergeability delegate_issue pause_landing_queue resume_landing_queue read_epic analyze_walkthrough_segment],
    "proposals" => %w[propose_job propose_epic propose_epic_with_jobs list_proposals delete_proposal set_bookmark schedule_recurring],
    "whiteboard" => %w[read_scene draw_shape draw_text draw_line draw_arrow draw_freedraw draw_frame draw_embed draw_image move_element delete_element save_canvas clear_canvas update_scene]
  }.freeze

  def self.for_run(run, workspace_path:)
    new(run: run, workspace_path: workspace_path).to_s
  end

  def self.for_chat(repository:, chat_session:)
    new(repository: repository, chat_session: chat_session).to_s
  end

  def self.chat_elaboration_epic(chat_session)
    return unless chat_session&.user&.developer?

    new(chat_session: chat_session).send(:chat_elaboration_epic)
  end

  def initialize(run: nil, workspace_path: nil, repository: nil, chat_session: nil)
    @run = run
    @workspace_path = workspace_path && Pathname.new(workspace_path)
    @chat_session = chat_session
    @repository = repository || run&.job&.repository || chat_session&.repository
  end

  def to_s
    lines = [ "Agent environment snapshot:" ]
    if @run
      lines.concat(run_lines)
    else
      lines.concat(chat_lines)
    end
    lines.join("\n")
  end

  def apply_to(prompt)
    body = prompt.to_s
    return body if body.include?("Agent environment snapshot:")

    [ to_s, body ].join("\n\n---\n\n")
  end

  private

  attr_reader :run, :workspace_path, :repository, :chat_session

  def run_lines
    job = run.job
    workflow = run.workflow
    step = run.step
    lines = [
      "- Repository: #{repository.slug} (default branch: #{repository.default_branch}, credential mode: #{job.credential_mode})",
      "- Job: ##{job.id} kind=#{job.kind} state=#{job.state} priority=#{job.priority}#{job_target_suffix(job)}",
      "- Workflow: ##{workflow&.id || 'unknown'} trigger=#{workflow&.trigger_kind || run.trigger_kind} state=#{workflow&.state || 'unknown'}",
      "- Step/Run: #{step&.kind || 'unknown'} step ##{step&.id || 'unknown'}, run ##{run.id}, iteration #{run.iteration}",
      "- Agent provider: #{run.agent_provider.presence || workflow&.agent_provider || job.agent_provider}",
      "- Workspace: #{workspace_path || '(not available)'}",
      "- Branch/base: #{branch_summary(job)}",
      "- MCP/tools: #{mcp_tool_summary(step)}"
    ]

    lines.concat(admin_links(job, workflow, run))
    lines.concat(workspace_lines)
    lines.concat(coverage_lines)
    lines
  end

  def chat_lines
    lines = [
      "- Chat: ##{chat_session&.id || 'new'}#{repository ? " scoped to #{repository.slug}" : ' with no pinned repository'}",
      "- Workspace: #{chat_workspace_label}",
      "- Agent provider: Claude chat turn with `syrus-chat-sidecar` MCP tools.",
      "- Tool availability: no commit, push, or PR-opening tool is available in chat; draft proposals or schedules for operator confirmation.",
      "- Repository checkout rule: attached checkouts under `/syrus-home/.syrus/chat-workspaces/*/repositories/` are read-only; never use Write, Edit, or Bash to create, modify, delete, rename, move, format, or generate files there. Propose Syrus Jobs or Epics for code changes and wait for operator confirmation.",
      "- Writable area: attached repository checkouts must not be written. Do not write memory to the filesystem -- use the Syrus memory MCP tools instead (see Memory section below).",
      "- Repository freshness: attached checkouts may drift; use `repo_info`, `git fetch`, or `git pull --ff-only` inside an attached repo when current state matters."
    ]

    lines.concat(chat_repository_lines)
    lines.concat(chat_elaboration_epic_lines)
    lines.concat(chat_tool_lines)
    lines.concat(recent_proposal_activity_lines)
    lines
  end

  def job_target_suffix(job)
    parts = []
    parts << "issue=#{repository.slug}##{job.issue_number}" if job.issue_number.present?
    parts << "pr=##{job.pr_number}" if job.pr_number.present?
    parts << "external_pr=##{job.external_pr_number}" if job.external_pr_number.present?
    parts.empty? ? "" : " (#{parts.join(', ')})"
  end

  def branch_summary(job)
    bits = []
    bits << "current=#{git_current_branch || job.branch_name || '(created by workspace setup)'}"
    bits << "base=#{repository.default_branch}"
    bits << "remote_head=#{run.head_sha}" if run.head_sha.present?
    bits << "pr_mergeable=#{job.pr_mergeable.inspect}" unless job.pr_mergeable.nil?
    bits.join(", ")
  end

  def mcp_tool_summary(step)
    required_tools = required_mcp_tools_for(step)
    if required_tools.any?
      tool_list = required_tools.map { |tool| "`#{tool}`" }.join(", ")
      "run sidecar `syrus-mcp-sidecar` must be connected; this step must call #{tool_list}."
    else
      "run sidecar `syrus-mcp-sidecar` is configured; this step has no required MCP submission tool."
    end
  end

  def required_mcp_tools_for(step)
    return [] unless step
    Step::Kind.fetch(step.kind).required_mcp_tools
  rescue ArgumentError
    []
  end

  def admin_links(job, workflow, run)
    host = ENV["SYRUS_APP_HOST"].to_s.sub(%r{/\z}, "")
    return [] if host.blank?

    links = [ "#{host}/jobs/#{job.id}" ]
    links << "#{host}/admin/workflows/#{workflow.id}" if workflow
    links << "#{host}/admin/runs/#{run.id}/transcript"
    [ "- Operator links: #{links.join(', ')}" ]
  end

  def workspace_lines
    return [ "- Workspace status: path unavailable to snapshot." ] unless workspace_path
    return [ "- Workspace status: not present on disk yet." ] unless workspace_path.directory?

    lines = [
      "- Git status: #{git_status_summary}",
      "- Prepare plan: #{prepare_summary}",
      "- Dependency signals: #{dependency_summary}",
      "- Graders: #{grader_summary}",
      "- Package scripts: #{package_script_summary}",
      "- Repository freshness: `git fetch` is allowed; use `git pull --ff-only` only when you intentionally need a current local view."
    ]
    lines
  end

  def prepare_summary
    plan = RepoPrepPlan.for(workspace_path)
    commands = plan.commands.any? ? plan.commands.join("; ") : "none"
    [ "#{plan.source}: #{commands}", plan.note ].compact.join(" (") + (plan.note ? ")" : "")
  rescue StandardError => e
    "unavailable (#{e.class}: #{e.message})"
  end

  def grader_summary
    plan = RepoGradePlan.for(workspace_path)
    return "#{plan.source}: none#{plan.note ? " (#{plan.note})" : ''}" if plan.graders.empty?

    rendered = plan.graders.first(MAX_GRADER_LINES).map do |grader|
      required = grader.required ? "required" : "optional"
      "#{grader.name}=#{grader.command.inspect} (#{required})"
    end
    rendered << "... #{plan.graders.size - MAX_GRADER_LINES} more" if plan.graders.size > MAX_GRADER_LINES
    "#{plan.source}: #{rendered.join('; ')}"
  rescue StandardError => e
    "unavailable (#{e.class}: #{e.message})"
  end

  def dependency_summary
    signals = []
    signals << "Gemfile" if workspace_path.join("Gemfile").exist?
    signals << "node_modules" if workspace_path.join("node_modules").directory?
    signals << "package-lock.json" if workspace_path.join("package-lock.json").exist?
    signals << "yarn.lock" if workspace_path.join("yarn.lock").exist?
    signals << "pnpm-lock.yaml" if workspace_path.join("pnpm-lock.yaml").exist?
    signals << ".bundle" if workspace_path.join(".bundle").directory?
    signals.presence&.join(", ") || "no common dependency signals found"
  end

  def package_script_summary
    path = workspace_path.join("package.json")
    return "none (no package.json)" unless path.file?

    scripts = JSON.parse(path.read).fetch("scripts", {})
    return "none" if scripts.blank?

    scripts.first(MAX_SCRIPT_LINES).map { |name, command| "#{name}=#{command.inspect}" }.join("; ").tap do |summary|
      extra = scripts.size - MAX_SCRIPT_LINES
      summary << "; ... #{extra} more" if extra.positive?
    end
  rescue JSON::ParserError => e
    "unavailable (package.json parse error: #{e.message})"
  rescue StandardError => e
    "unavailable (#{e.class}: #{e.message})"
  end

  def git_current_branch
    git("branch", "--show-current").presence
  end

  def git_status_summary
    status = git("status", "--short")
    return "clean" if status.blank?

    count = status.lines.size
    sample = status.lines.first(5).map(&:strip).join("; ")
    "#{count} changed path#{'s' unless count == 1}: #{sample}"
  rescue StandardError => e
    "unavailable (#{e.class}: #{e.message})"
  end

  def git(*args)
    return nil unless workspace_path&.directory?

    GitRunner.new.run(*args, chdir: workspace_path.to_s).strip
  rescue StandardError
    nil
  end

  def chat_workspace_label
    return "(not created yet)" unless chat_session

    ChatWorkspace.path_for(chat_session).to_s
  end

  def chat_repository_lines
    repos = if chat_session
      chat_session.attached_repositories.order(:owner, :name).to_a
    else
      []
    end
    repos.unshift(repository) if repository && repos.none? { |repo| repo.id == repository.id }
    return [ "- Attached repositories: none; call `attach_repository(slug)` before inspecting code." ] if repos.empty?

    lines = [ "- Attached repositories:" ]
    repos.each do |repo|
      checkout = chat_session ? ChatWorkspace.repo_path_for(chat_session, repo) : nil
      state = checkout&.join(".git")&.directory? ? checkout.to_s : "not cloned; call `attach_repository(\"#{repo.slug}\")`"
      lines << "  - #{repo.slug} default=#{repo.default_branch} checkout=#{state}"
    end
    lines
  end

  def chat_elaboration_epic_lines
    epic = chat_elaboration_epic
    return [] unless epic

    description = epic.description.to_s
    clipped_description = if description.bytesize > ELABORATION_EPIC_DESCRIPTION_BYTES
      "#{description.safe_byteslice(0, ELABORATION_EPIC_DESCRIPTION_BYTES)}..."
    else
      description.presence || "(blank)"
    end

    [
      "- Developer elaboration mode: active for #{epic.slug} (id=#{epic.id}, state=#{epic.state}, child_jobs=0).",
      "- Elaboration Epic title: #{epic.title}",
      "- Elaboration Epic description: #{clipped_description}"
    ]
  end

  def chat_elaboration_epic
    return @chat_elaboration_epic if defined?(@chat_elaboration_epic)

    @chat_elaboration_epic = candidate_elaboration_epics.find do |epic|
      epic.backlog? && !epic.jobs.exists?
    end
  end

  def candidate_elaboration_epics
    return [] unless chat_session

    ids = first_user_message_epic_numbers + read_epic_result_ids
    ids.uniq.filter_map { |value| find_user_epic(value) }
  end

  def first_user_message_epic_numbers
    text = chat_session.messages.where(role: "user").order(:created_at, :id).first&.content&.fetch("text", nil).to_s
    text.scan(/\bEPIC-(\d+)\b/i).flatten.map(&:to_i)
  end

  def read_epic_result_ids
    chat_session.messages
                .where(role: "tool_result", tool_name: "read_epic")
                .order(:created_at, :id)
                .filter_map { |message| read_epic_result_id(message.content) }
  end

  def read_epic_result_id(content)
    payload = parse_tool_result_payload(content)
    epic = payload["epic"]
    return unless epic.is_a?(Hash)
    return unless epic["state"] == "backlog"
    return unless Array(payload["child_jobs"]).empty?

    Integer(epic["id"], exception: false)
  end

  def parse_tool_result_payload(content)
    result = content["result"]
    text = if result.is_a?(Array)
      result.filter_map { |item| item["text"] if item.is_a?(Hash) }.join
    else
      result.to_s
    end
    return {} if text.blank?

    JSON.parse(text)
  rescue JSON::ParserError
    {}
  end

  def find_user_epic(value)
    return unless value

    chat_session.user.epics.includes(:repository).find_by(id: value) ||
      chat_session.user.epics.includes(:repository).find_by(number: value)
  end

  def chat_tool_lines
    lines = [ "- MCP tool groups:" ]
    CHAT_TOOL_GROUPS.each do |label, tools|
      lines << "  - #{label}: #{tools.join(', ')}"
    end
    lines
  end

  def recent_proposal_activity_lines
    return [] unless chat_session

    recent = chat_session.proposals
      .includes(:job, :epic, child_proposals: :job)
      .where(state: %w[confirmed rejected withdrawn])
      .where(updated_at: 24.hours.ago..)
      .order(updated_at: :desc)
      .limit(10)
      .to_a
    return [] if recent.empty?

    [ "- Recent proposal activity:" ] + recent.map { |proposal| "  #{recent_proposal_activity_line(proposal)}" }
  end

  def recent_proposal_activity_line(proposal)
    if proposal.confirmed? && proposal.github_issue_number.present?
      return "- GitHub issue ##{proposal.github_issue_number} \"#{proposal.title}\" confirmed (proposal slug: #{proposal.slug})"
    end

    case proposal.materialized_record
    when Epic
      jobs = proposal.child_proposals.select { |child| child.job_id.present? }.map { |child| proposal_child_job_label(child.job) }
      suffix = jobs.any? ? " with jobs: #{jobs.join(', ')}" : ""
      "- #{proposal.epic.slug} #{proposal.epic.title.inspect} confirmed#{suffix} (proposal slug: #{proposal.slug})"
    when Job
      "- #{proposal.job.slug} #{proposal.job.issue_title.inspect} confirmed (proposal slug: #{proposal.slug})"
    else
      "- Proposal #{proposal.title.inspect} was #{proposal.state} (proposal slug: #{proposal.slug})"
    end
  end

  def proposal_child_job_label(job)
    "#{job.slug} #{job.issue_title.inspect}"
  end

  def coverage_lines
    return [] unless workspace_path&.directory? && @run

    coverage_plan = begin
      SyrusYml.load_repo(workspace_path).coverage
    rescue StandardError
      nil
    end
    return [] unless coverage_plan

    lines = [ "## Test coverage", coverage_config_line(coverage_plan) ]

    artifact, source_label = find_coverage_data
    if artifact
      lines << "Last run: #{format_coverage_summary(artifact)} (#{source_label})"
      lines << coverage_miss_warning(artifact) if artifact["threshold_miss"]
      uncovered = coverage_uncovered_files(artifact)
      if uncovered.any?
        lines << "Low-coverage changed files:"
        uncovered.each do |entry|
          count = entry[:count]
          lines << "  - #{entry[:file]} (#{entry[:pct]} — #{count} uncovered changed line#{count == 1 ? '' : 's'})"
        end
      end
    else
      lines << "Last run: no coverage data yet"
    end

    lines
  end

  def coverage_config_line(plan)
    parts = []
    if plan.threshold
      parts << "lines ≥#{format_coverage_pct(plan.threshold.lines)}%" if plan.threshold.lines
      parts << "PR delta ≥#{format_coverage_pct(plan.threshold.pr_lines)}%" if plan.threshold.pr_lines
    end
    config = parts.empty? ? "no thresholds configured" : parts.join(", ")
    "Configured: #{config} (on_miss: #{plan.on_miss})"
  end

  def find_coverage_data
    @run.job.workflows.order(created_at: :desc).each do |w|
      artifact = Workflow::CoverageArtifact.read(w)
      next unless artifact.present? && !artifact["coverage_unavailable"]

      age = coverage_age_label(w.created_at)
      return [ artifact, "workflow ##{w.id}, #{age}" ]
    end

    snapshot = CoverageSnapshot
      .where(repository: repository)
      .on_default_branch
      .recent(1)
      .first
    return [ nil, nil ] unless snapshot

    artifact = {
      "summary" => {
        "lines_pct"   => snapshot.lines_pct,
        "branches_pct" => snapshot.branches_pct
      }
    }
    [ artifact, "default branch, #{coverage_age_label(snapshot.created_at)}" ]
  end

  def format_coverage_summary(artifact)
    summary = artifact["summary"] || {}
    parts = []
    parts << "lines #{format_coverage_pct(summary["lines_pct"])}%" if summary["lines_pct"]
    parts << "branches #{format_coverage_pct(summary["branches_pct"])}%" if summary["branches_pct"]
    parts.empty? ? "no data" : parts.join(", ")
  end

  def coverage_miss_warning(artifact)
    details = artifact["threshold_miss_details"] || {}
    parts = []
    if details["lines_pct"] && details["threshold_lines"] && details["lines_pct"] < details["threshold_lines"]
      parts << "lines #{format_coverage_pct(details["lines_pct"])}% < #{format_coverage_pct(details["threshold_lines"])}%"
    end
    if details["pr_delta_pct"] && details["threshold_pr_lines"] && details["pr_delta_pct"] < details["threshold_pr_lines"]
      parts << "PR delta #{format_coverage_pct(details["pr_delta_pct"])}% < #{format_coverage_pct(details["threshold_pr_lines"])}%"
    end
    miss_str = parts.any? ? parts.join(", ") : "see artifact for details"
    "⚠️  Threshold miss: #{miss_str}"
  end

  def coverage_uncovered_files(artifact)
    diff_annotations = artifact["diff_annotations"] || {}
    files = artifact["files"] || {}

    result = diff_annotations.filter_map do |filepath, lines_map|
      uncovered_count = lines_map.values.count { |status| status == "uncovered" }
      next if uncovered_count == 0

      file_pct = files.dig(filepath, "lines_pct")
      pct_str = file_pct ? "#{file_pct.round}%" : "coverage unknown"
      { file: filepath, pct: pct_str, count: uncovered_count }
    end

    result.sort_by { |entry| [ -entry[:count], entry[:file] ] }
  end

  def format_coverage_pct(value)
    return "?" unless value

    format("%.1f", value).sub(/\.0$/, "")
  end

  def coverage_age_label(time)
    return "unknown time" unless time

    seconds = (Time.current - time).to_i.abs
    if seconds < 60
      "just now"
    elsif seconds < 3600
      mins = seconds / 60
      "#{mins} minute#{mins == 1 ? '' : 's'} ago"
    elsif seconds < 86400
      hours = seconds / 3600
      "#{hours} hour#{hours == 1 ? '' : 's'} ago"
    else
      days = seconds / 86400
      "#{days} day#{days == 1 ? '' : 's'} ago"
    end
  end
end
