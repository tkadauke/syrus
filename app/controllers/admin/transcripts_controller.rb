module Admin
  # Renders a captured agent-session transcript_jsonl as a navigable
  # event stream — system init (with model + tool list), user
  # prompts, assistant text, tool calls + results, and the final
  # result summary. Backs the "Open transcript" link on the
  # admin-only Run diagnostic panel.
  class TranscriptsController < BaseController
    def show
      @run = Run.find(params[:run_id])
      @session = @run.claude_session

      unless @session
        redirect_back fallback_location: job_path(@run.job),
                      alert: "No agent session was captured for Run ##{@run.id}."
        return
      end

      @transcript = ClaudeTranscript.new(@session.transcript_jsonl)
      @summary = @transcript.summary
    end

    # Raw JSONL download for offline analysis (jq grep, etc.)
    def download
      @run = Run.find(params[:run_id])
      session = @run.claude_session

      unless session
        redirect_back fallback_location: job_path(@run.job),
                      alert: "No agent session captured for Run ##{@run.id}."
        return
      end

      send_data session.transcript_jsonl,
                filename: "run-#{@run.id}-#{session.session_id}.jsonl",
                type: "application/jsonl"
    end
  end
end
