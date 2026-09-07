module SyrusBrowser
  # Resolves "which browser session does this tool call operate on" from the
  # MCP server_context, independently of "where does captured evidence go"
  # (see ArtifactSinks) -- two axes DOC-17/the browser provider Job keeps
  # deliberately separate, both resolved from the same call context.
  #
  # Three branches, checked in order of specificity:
  #
  #   1. server_context[:runtime_session] -- set directly by
  #      RuntimeSessionProvider when it delegates snapshot/inspect/launch
  #      into these same tool classes instead of re-driving Playwright.
  #   2. server_context[:chat_session] -- a live Coding Mode chat MCP call
  #      with no current Run; resolved to that chat's active browser
  #      RuntimeSession.
  #   3. otherwise -- the existing workflow Run path (visual_review and any
  #      other agentic step), resolved via Mcp::Tools.run_from_context.
  #
  # Local Mode routing (a third, materially different daemon-backed browser)
  # is intentionally not a branch here yet -- DOC-16's own broker work adds
  # it later. Leaving it out is itself the seam: a future branch slots in
  # beside #for_chat_session without touching the other two.
  class SessionContext
    NoActiveSessionError = Class.new(StandardError)

    Result = Struct.new(:session_key, :artifact_sink, :owner, keyword_init: true)

    class << self
      def resolve(server_context)
        if server_context.key?(:runtime_session)
          for_runtime_session(server_context[:runtime_session])
        elsif server_context.key?(:chat_session)
          for_chat_session(server_context[:chat_session])
        else
          for_run(Mcp::Tools.run_from_context(server_context))
        end
      end

      def for_run(run)
        Result.new(session_key: "run:#{run.id}", artifact_sink: ArtifactSinks::Null.new, owner: run)
      end

      def for_runtime_session(runtime_session)
        Result.new(
          session_key: "runtime_session:#{runtime_session.id}",
          artifact_sink: ArtifactSinks::ChatMedia.new(runtime_session.chat_session),
          owner: runtime_session
        )
      end

      def for_chat_session(chat_session)
        runtime_session = active_browser_session_for(chat_session)
        raise NoActiveSessionError, "no active browser runtime session for this chat" unless runtime_session

        for_runtime_session(runtime_session)
      end

      private

      def active_browser_session_for(chat_session)
        scope = chat_session.runtime_sessions.active.for_provider(RuntimeSessionProvider.provider_key)
        scope.primary.first || scope.first
      end
    end
  end
end
