require "open3"

# Generates a short plain-English summary of a GitHub issue using the
# Claude CLI. Returns nil if the call fails or the CLI is unavailable.
class IssueSummarizer
  TIMEOUT = 60

  def initialize(oauth_token)
    @oauth_token = oauth_token
  end

  def summarize(title, body)
    prompt = <<~PROMPT.strip
      In 2-3 sentences, summarize what this GitHub issue is asking for. Be concrete and technical. No preamble.

      Title: #{title}

      #{body}
    PROMPT

    env = { "CLAUDE_CODE_OAUTH_TOKEN" => @oauth_token }
    cmd = [ "claude", "--print", "--output-format", "text", prompt ]

    output = nil
    Timeout.timeout(TIMEOUT) do
      output, status = Open3.capture2e(env, *cmd, chdir: Rails.root.to_s)
      return output.strip.presence if status.success?
    end
    nil
  rescue StandardError => e
    Rails.logger.warn("[IssueSummarizer] #{e.class}: #{e.message}")
    nil
  end
end
