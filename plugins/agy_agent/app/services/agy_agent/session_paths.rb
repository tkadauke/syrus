require "digest"
require "fileutils"

module AgyAgent
  class SessionPaths
    SESSION_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,200}\z/

    def self.valid_session_id?(session_id)
      session_id.to_s.match?(SESSION_ID_PATTERN)
    end

    def self.canonical_path_for(home:, cwd:, session_id:)
      return unless valid_session_id?(session_id)

      File.join(
        home.to_s,
        ".gemini",
        "antigravity-cli",
        "conversations",
        workspace_key(cwd),
        "#{session_id}.jsonl"
      )
    end

    def self.transcript_path_for(home:, cwd:, session_id:)
      return unless valid_session_id?(session_id)

      canonical = canonical_path_for(home: home, cwd: cwd, session_id: session_id)
      return canonical if canonical && File.exist?(canonical)

      transcript_candidates(home: home, session_id: session_id).max_by { |path| File.mtime(path) }
    end

    def self.transcript_jsonl(home:, cwd:, session_id:)
      path = transcript_path_for(home: home, cwd: cwd, session_id: session_id)
      return if path.blank? || !File.exist?(path)

      File.read(path)
    end

    def self.restore!(home:, cwd:, session_id:, transcript_jsonl:)
      path = canonical_path_for(home: home, cwd: cwd, session_id: session_id)
      return unless path
      return if transcript_jsonl.blank?

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, transcript_jsonl)
      path
    end

    def self.workspace_key(cwd)
      Digest::SHA256.hexdigest(File.expand_path(cwd.to_s))[0, 32]
    end

    def self.transcript_candidates(home:, session_id:)
      roots = [
        File.join(home.to_s, ".gemini", "antigravity-cli", "conversations"),
        File.join(home.to_s, ".gemini", "antigravity", "conversations")
      ]
      roots.flat_map { |root| Dir.glob(File.join(root, "**", "#{session_id}.jsonl")) }
    end
  end
end
