module ClaudeAgent
  module SessionPaths
    # Path Claude Code uses to store its session JSONL on disk:
    # `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`
    # The "project" component is the absolute cwd with every "/"
    # AND every "." replaced by "-". Verified empirically against a
    # running production worker — claude-code encodes both characters
    # to a single dash, so "/.syrus" becomes "--syrus" (double-dash
    # from the slash + dot pair).
    # Example: cwd "/syrus-home/.syrus/workflows/124" →
    #          "-syrus-home--syrus-workflows-124"
    PATH_ENCODE_PATTERN = %r{[/.]}.freeze
    SESSION_ID_PATTERN = /\A[A-Za-z0-9_-]+\z/

    def self.canonical_path_for(home:, cwd:, session_id:)
      encoded = cwd.to_s.gsub(PATH_ENCODE_PATTERN, "-")
      File.join(home, ".claude", "projects", encoded, "#{session_id}.jsonl")
    end

    def self.canonical_transcript_jsonl(home:, cwd:, session_id:)
      normalized = session_id.to_s
      return unless normalized.match?(SESSION_ID_PATTERN)

      path = canonical_path_for(home: home, cwd: cwd, session_id: normalized)
      File.read(path) if File.exist?(path)
    end

    # Claude Code (SDK/headless mode -- what Syrus always runs, both chat and
    # workflow Runs) writes subagent (Task/Agent tool) conversations to
    # sibling per-agent JSONL files instead of interleaving them into the
    # main session transcript: `<dir>/<session-uuid>/subagents/agent-<id>.jsonl`
    # next to `<dir>/<session-uuid>.jsonl`, each paired with an
    # `agent-<id>.meta.json` carrying the spawning tool_use id (`toolUseId`).
    # Verified empirically against this environment's own live claude-code
    # session by spawning a real subagent and inspecting the resulting files
    # on disk (isSidechain lines are NOT interleaved inline in SDK-CLI mode,
    # contrary to interactive-CLI transcripts).
    def self.canonical_subagents_dir_for(home:, cwd:, session_id:)
      encoded = cwd.to_s.gsub(PATH_ENCODE_PATTERN, "-")
      File.join(home, ".claude", "projects", encoded, session_id.to_s, "subagents")
    end
  end
end
