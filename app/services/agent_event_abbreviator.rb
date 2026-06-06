# Pure-function helpers that turn a claude-code tool_use or
# tool_result event into a single short line for the live JobLog
# transcript. Same shape claude-cli renders inline ("Bash(rg foo)",
# "Read(app/models/run.rb)", etc.) — keeps the live view scannable
# even when the agent is doing 99 Bash calls in a row.
#
# The full structured data still goes into the JSONL on disk and
# is rendered with full fidelity by the admin transcript viewer
# (see ClaudeTranscript). This abbreviator is for the live readout
# only.
module AgentEventAbbreviator
  MAX_LINE = 200
  MAX_CMD  = 140

  module_function

  def tool_use(name, input, path_roots: [])
    input = {} unless input.is_a?(Hash)
    head = "● #{tool_label(name)}"
    detail = tool_detail(name, input, path_roots: path_roots)
    detail.present? ? "#{head}(#{truncate(detail, MAX_CMD)})" : head
  end

  def tool_result(content, error: false)
    body = result_body(content)
    prefix = error ? "  ⎿ ✗ " : "  ⎿ "
    truncate(prefix + body, MAX_LINE)
  end

  # ---------------------------------------------------------------

  def tool_label(name)
    # MCP tools come over as "mcp__<server>__<tool>" — surface
    # just the human-readable bit so the transcript reads as
    # "submit_summary(...)" not "mcp__syrus__submit_summary(...)".
    return name.to_s.split("__", 3).last if name.to_s.start_with?("mcp__")
    name.to_s
  end

  # Per-tool one-line summary of the input. Picks the field that
  # the human reading the transcript actually wants to see. Used
  # both by tool_use (to format the abbreviated string for JobLog)
  # and by the chat presentation layer (to derive the summary
  # detail off a structured ChatMessage at render time).
  def tool_detail(name, input, path_roots: [])
    detail = case name.to_s
    when "Bash"           then first_line(input["command"].to_s)
    when "Read"           then input["file_path"].to_s
    when "Edit", "Write"  then input["file_path"].to_s
    when "NotebookEdit"   then input["notebook_path"].to_s
    when "Glob"           then input["pattern"].to_s
    when "Grep"
      base = input["pattern"].to_s
      input["path"].present? ? "#{base} in #{input['path']}" : base
    when "WebFetch"       then input["url"].to_s
    when "WebSearch"      then input["query"].to_s
    when "TodoWrite"      then "#{Array(input['todos']).size} item(s)"
    when "Task", "Agent"  then input["description"].to_s.presence || first_line(input["prompt"].to_s)
    when "ToolSearch"     then input["query"].to_s
    when /\Amcp__/
      # MCP tools — show first interesting field
      candidate = input.values.find { |v| v.is_a?(String) && v.length.positive? }
      first_line(candidate.to_s)
    else
      # Unknown tool — show the input compactly
      first_line(input.to_json)
    end

    shorten_paths(detail.to_s, path_roots)
  end

  def result_body(content)
    case content
    when String
      first_line(content)
    when Array
      # tool_result content is sometimes [{type: "text", text: "..."}, ...]
      # or [{type: "tool_reference", tool_name: "..."}].
      bits = content.filter_map do |c|
        next unless c.is_a?(Hash)
        case c["type"]
        when "text"           then c["text"]
        when "tool_reference" then "→ #{c['tool_name']}"
        end
      end
      first_line(bits.join(" "))
    when nil
      "(empty)"
    else
      first_line(content.to_s)
    end
  end

  # Same as result_body but preserves newlines — chat presentation
  # wants the multi-line content rendered inside the expand body,
  # whereas JobLog wants the first line for its one-line audit row.
  def full_result_body(content)
    case content
    when String
      content
    when Array
      content.filter_map do |c|
        next unless c.is_a?(Hash)
        case c["type"]
        when "text"           then c["text"]
        when "tool_reference" then "→ #{c['tool_name']}"
        end
      end.join("\n")
    when nil
      "(empty)"
    else
      content.to_s
    end
  end

  def first_line(s)
    s.to_s.lines.first.to_s.strip
  end
  private_class_method :first_line

  def truncate(s, n)
    s.length > n ? "#{s[0, n - 1]}…" : s
  end
  private_class_method :truncate

  def shorten_paths(text, path_roots)
    shortened = text.to_s
      .gsub(%r!(?:/[^\s'"`,:;\])}]+)+/\.syrus/chat-workspaces/\d+/repositories/[^/\s'"`,:;\])}]+/[^/\s'"`,:;\])}]+/?!) do |match|
        match.end_with?("/") ? "" : "."
      end
      .gsub(%r!(?:/[^\s'"`,:;\])}]+)+/\.syrus/workflows/\d+/?!) do |match|
        match.end_with?("/") ? "" : "."
      end

    roots = Array(path_roots).filter_map { |root| root.to_s.presence&.delete_suffix("/") }
                             .uniq
                             .sort_by { |root| -root.length }
    roots.reduce(shortened) do |out, root|
      escaped = Regexp.escape(root)
      out.gsub(%r{#{escaped}/}, "")
         .gsub(/#{escaped}(?=$|[\s'"`),:;\]}])/, ".")
    end
  end
  private_class_method :shorten_paths
end
