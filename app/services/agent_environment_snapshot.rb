require "json"

class AgentEnvironmentSnapshot
  MAX_SCRIPT_LINES = 8
  MAX_GRADER_LINES = 8

  CHAT_TOOL_GROUPS = {
    "repository context" => %w[attach_repository repo_info read_repo_document list_repo_documents read_repo_notes add_repo_note remove_repo_note],
    "live Syrus state" => %w[list_jobs read_job read_pr list_open_issues list_open_prs cancel_job retry_job rebase_job read_epic],
    "proposals" => %w[propose_job propose_epic propose_epic_with_jobs propose_issue list_proposals delete_proposal set_bookmark schedule_recurring],
    "whiteboard" => %w[read_scene draw_shape draw_text draw_line draw_arrow draw_freedraw draw_frame draw_embed draw_image move_element delete_element clear_canvas update_scene]
  }.freeze

  def self.for_run(run, workspace_path:)
    new(run: run, workspace_path: workspace_path).to_s
  end

  def self.for_chat(repository:, chat_session:)
    new(repository: repository, chat_session: chat_session).to_s
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
      "- MCP/tools: run sidecar `syrus-mcp-sidecar` is configured with `submit_summary`; implement/respond turns normally do not need it, summarize/summarize_amend turns do."
    ]

    lines.concat(admin_links(job, workflow, run))
    lines.concat(workspace_lines)
    lines
  end

  def chat_lines
    lines = [
      "- Chat: ##{chat_session&.id || 'new'}#{repository ? " scoped to #{repository.slug}" : ' with no pinned repository'}",
      "- Workspace: #{chat_workspace_label}",
      "- Agent provider: Claude chat turn with `syrus-chat-sidecar` MCP tools.",
      "- Tool availability: no commit, push, or PR-opening tool is available in chat; draft proposals or schedules for operator confirmation.",
      "- Repository checkout rule: attached checkouts under `/syrus-home/.syrus/chat-workspaces/*/repositories/` are read-only; never use Write, Edit, or Bash to create, modify, delete, rename, move, format, or generate files there. Propose Syrus Jobs, Epics, or issues for code changes and wait for operator confirmation.",
      "- Writable area: only your own non-repository chat memory directory may be written when needed; attached repository checkouts must not be written.",
      "- Repository freshness: attached checkouts may drift; use `repo_info`, `git fetch`, or `git pull --ff-only` inside an attached repo when current state matters."
    ]

    lines.concat(chat_repository_lines)
    lines.concat(chat_tool_lines)
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

  def chat_tool_lines
    lines = [ "- MCP tool groups:" ]
    CHAT_TOOL_GROUPS.each do |label, tools|
      lines << "  - #{label}: #{tools.join(', ')}"
    end
    lines
  end
end
