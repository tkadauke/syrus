require "json"

# Redacts short-lived MCP invocation tokens from a Codex rollout JSONL while
# leaving the file in Codex's own on-disk format.
#
# Why this exists: a rollout is a transcript, and an agent that ran `ps`, dumped
# its MCP config, or printed a proxy command line captures that turn's signed
# invocation token into ordinary transcript text (`stdout`, `aggregated_output`,
# `content[].text`, ...). Those tokens are scoped to the turn that minted them,
# so they must not travel into a later resume.
#
# The previous approach stripped them by replacing the rollout wholesale with a
# transcript synthesized from ChatMessage rows. That worked for secrets and
# broke resume: the synthesized stream uses Codex's *stdout event* vocabulary
# (`thread.started` / `item.started` / `item.completed`), while the rollout
# Codex reads back uses its on-disk vocabulary (`session_meta` / `response_item`
# / `event_msg`). Codex could not find session metadata in the replacement and
# reported the rollout as empty, which made every subsequent turn in that chat
# fail. Redacting in place keeps both properties: the secrets go, the format
# stays readable.
#
# Redaction is structural, not textual: every string value in the JSON is
# rewritten, so a token is removed wherever it appears without the caller having
# to enumerate the fields Codex happens to use.
class CodexRolloutSanitizer
  REDACTED = "[redacted]".freeze

  # The MCP proxy's own env/header names, plus the token shape itself. The
  # first two catch `KEY=value` and `Header: value` renderings; the last
  # catches a bare token echoed on its own (the proxy is invoked as
  # `syrus-mcp-proxy --token <value>`).
  TOKEN_PATTERNS = [
    /(SYRUS_MCP_PROXY_INVOCATION_CONTEXT\s*[=:]\s*)(\S+)/,
    /(X-Syrus-Invocation-Context\s*:\s*)(\S+)/,
    /(--token[=\s]+)(\S+)/
  ].freeze

  # A rollout Codex wrote itself opens with this. Anything else is either a
  # transcript some earlier version of Syrus synthesized, or a file Codex will
  # refuse to read.
  NATIVE_HEADER_TYPE = "session_meta".freeze

  class << self
    # True when `jsonl` is a rollout in Codex's own on-disk format, i.e. one
    # Codex can actually resume from.
    def native?(jsonl)
      first = jsonl.to_s.lstrip.lines.first
      return false if first.blank?

      JSON.parse(first)["type"] == NATIVE_HEADER_TYPE
    rescue JSON::ParserError
      false
    end

    # Returns the rollout with invocation tokens redacted, preserving line
    # order, line types and the overall JSONL shape. Lines that do not parse
    # are passed through untouched rather than dropped: losing a line would
    # corrupt the transcript, and a non-JSON line cannot carry a structured
    # token we are able to locate.
    def call(jsonl)
      return jsonl if jsonl.blank?

      jsonl.each_line.map { |line| sanitize_line(line) }.join
    end

    private

    def sanitize_line(line)
      stripped = line.strip
      return line if stripped.empty?

      parsed = JSON.parse(stripped)
      newline = line.end_with?("\n") ? "\n" : ""
      JSON.generate(redact(parsed)) + newline
    rescue JSON::ParserError
      line
    end

    def redact(value)
      case value
      when Hash  then value.transform_values { |v| redact(v) }
      when Array then redact_array(value)
      when String then redact_string(value)
      else value
      end
    end

    # An argv is stored as separate elements, so the token sits in the element
    # *after* the flag rather than inside the same string (`["syrus-mcp-proxy",
    # "--token", "<token>"]`). Real rollouts carry exactly this shape under
    # `payload.item.command`, so a per-string regex alone would miss it.
    def redact_array(value)
      value.each_with_index.map do |element, index|
        previous = value[index - 1] if index.positive?
        next REDACTED if element.is_a?(String) && previous.is_a?(String) && flag_expecting_token?(previous)

        redact(element)
      end
    end

    # Only the proxy's token flag. `--url` carries no secret, and redacting it
    # would make the transcript harder to read for no gain.
    def flag_expecting_token?(value)
      value == "--token"
    end

    def redact_string(value)
      TOKEN_PATTERNS.reduce(value) do |acc, pattern|
        acc.gsub(pattern) { "#{::Regexp.last_match(1)}#{REDACTED}" }
      end
    end
  end
end
