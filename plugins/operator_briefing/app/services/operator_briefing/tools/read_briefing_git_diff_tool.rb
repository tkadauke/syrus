require "mcp"

module OperatorBriefing
  module Tools
    class ReadBriefingGitDiffTool < MCP::Tool
      MAX_BYTES = 120_000

      tool_name "read_briefing_git_diff"

      description <<~DESC
        Read bounded git patch output for commits in the current briefing window.
        Use this to inspect repository changes since the last briefing.
      DESC

      input_schema(
        properties: {
          max_bytes: {
            type: "integer",
            description: "Maximum UTF-8 bytes to return. Defaults to 120000 and is capped at 120000."
          },
          path: {
            type: "string",
            description: "Optional repository-relative pathspec to narrow the patch."
          }
        }
      )

      class << self
        def call(server_context:, max_bytes: nil, path: nil)
          run = Mcp::Tools.run_from_context(server_context)
          briefing = Briefing.find_by!(job: run.job)
          limit = normalized_limit(max_bytes)
          workspace_path = StepWorkspace.for(run.step, run: run).path.to_s
          args = [
            "log",
            "--since=#{briefing.window_start.iso8601}",
            "--until=#{briefing.window_end.iso8601}",
            "--patch",
            "--stat",
            "--find-renames",
            "--no-ext-diff",
            "--"
          ]
          args << path.to_s if path.present?

          output = GitRunner.new.run(*args, chdir: workspace_path)
          text = CommandRedactor.redact(output.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: ""))
          truncated = text.bytesize > limit
          text = text.safe_byteslice(0, limit) if truncated

          MCP::Tool::Response.new([
            {
              type: "text",
              text: JSON.generate(
                repository: { id: briefing.repository_id, slug: briefing.repository.slug },
                window_start: briefing.window_start.iso8601,
                window_end: briefing.window_end.iso8601,
                path: path.presence,
                truncated: truncated,
                patch: text
              )
            }
          ])
        rescue GitRunner::GitError => e
          Mcp::Tools.invalid("git diff unavailable: #{CommandRedactor.redact(e.message)}")
        rescue StandardError => e
          Rails.logger.error("[OperatorBriefing::ReadBriefingGitDiffTool] #{e.class}: #{e.message}")
          MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
        end

        private

        def normalized_limit(value)
          Integer(value.presence || MAX_BYTES, exception: false).to_i.clamp(1_000, MAX_BYTES)
        end
      end
    end
  end
end
