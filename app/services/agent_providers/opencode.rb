module AgentProviders
  class Opencode < Base
    include Syrus::Plugin::AgentProvider

    def self.provider = "opencode"
    def self.display_name = "OpenCode (Ollama)"
    def self.available? = true

    # For summarize/summarize_amend steps, bypass OpenCode entirely —
    # local models can't reliably call the submit_summary MCP tool.
    # Instead, ask Ollama directly to write a PR title/body from the
    # diff and write the result straight onto the Run record.
    SUMMARIZE_STEP_KINDS = %w[ summarize summarize_amend ].freeze

    def run(prompt:, log_sink:, max_turns: nil)
      if SUMMARIZE_STEP_KINDS.include?(@run.step.kind)
        ollama_summarize!(log_sink: log_sink)
      else
        super
      end
    end

    private

    def ollama_summarize!(log_sink:)
      diff = GitRunner.new.run("diff", "origin/#{job.repository.default_branch}...HEAD",
                               chdir: workspace.path.to_s)
      model = job.user.opencode_model.presence || ENV.fetch("SYRUS_OPENCODE_MODEL", OpencodeInvocation::DEFAULT_OLLAMA_MODEL)

      log_sink.call("generating PR summary via Ollama (#{model})", kind: "system")

      messages = [
        { role: "system", content: "You are a concise technical writer producing GitHub PR copy." },
        { role: "user", content: summarize_prompt(diff) }
      ]

      response = OllamaChat.new(model: model).complete(messages)
      title, body, summary = parse_summary_response(response)

      log_sink.call("PR title: #{title}", kind: "system")

      @run.update!(
        agent_pr_title: title.presence || "Implement changes",
        agent_pr_body: body.presence,
        agent_summary: summary.presence || title
      )

      AgentInvocation::Result.new(
        turns: 1,
        exit_status: 0,
        timed_out: false,
        is_error: false,
        outcome: "success",
        final_text: title,
        session_id: nil
      )
    end

    def summarize_prompt(diff)
      <<~PROMPT
        Given the following git diff, write concise GitHub PR copy.

        Respond in EXACTLY this format (no extra text before or after):
        TITLE: <50-72 char imperative title, e.g. "Add markdown preview endpoint">
        BODY: <1-3 short markdown paragraphs explaining what and why>
        SUMMARY: <1-2 sentence operator-facing summary>

        Git diff:
        #{diff.to_s.slice(0, 8000)}
      PROMPT
    end

    def parse_summary_response(response)
      title   = response[/^TITLE:\s*(.+)$/i, 1]&.strip
      body    = response[/^BODY:\s*(.+?)(?=^SUMMARY:|$)/im, 1]&.strip
      summary = response[/^SUMMARY:\s*(.+)$/i, 1]&.strip
      [ title, body, summary ]
    end

    def invoke(workspace_path:, prompt:, log_sink:, timeout:, mcp:, resume_session_id:, **_ignored)
      opencode_home = WorkflowWorkspace.agent_home_for(workflow, provider)

      OpencodeInvocation.new(
        workspace_path,
        prompt: prompt,
        model: job.user.opencode_model.presence || ENV.fetch("SYRUS_OPENCODE_MODEL", OpencodeInvocation::DEFAULT_OLLAMA_MODEL),
        log_sink: log_sink,
        runner: RunJob.agent_runner,
        timeout: timeout,
        opencode_home: opencode_home,
        mcp_server: (mcp ? mcp_server : nil),
        resume_session_id: resume_session_id
      ).run
    end

    def mcp_server
      {
        command: sidecar_command,
        args: sidecar_args,
        env: sidecar_env
      }
    end
  end
end
