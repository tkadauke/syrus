module SyrusChatMcp
  HEAD_TAIL_BYTES = 4.kilobytes

  def self.success(payload)
    MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload) } ])
  end

  def self.invalid(reason)
    MCP::Tool::Response.new([ { type: "text", text: "Error: #{reason}" } ], error: true)
  end

  def self.tool_error(reason)
    MCP::Tool::Response.new([ { type: "text", text: reason } ], error: true)
  end

  def self.truncate_text(text, max_bytes)
    text = text.to_s
    return { text: text, truncated: false, bytes: text.bytesize } if text.bytesize <= max_bytes

    {
      text: safe_byteslice(text, 0, max_bytes),
      truncated: true,
      bytes: text.bytesize,
      omitted_bytes: text.bytesize - max_bytes
    }
  end

  def self.head_tail(text, bytes: HEAD_TAIL_BYTES)
    text = text.to_s
    return { head: text, tail: "", truncated: false, bytes: text.bytesize } if text.bytesize <= bytes * 2

    {
      head: safe_byteslice(text, 0, bytes),
      tail: safe_byteslice(text, -bytes, bytes),
      truncated: true,
      bytes: text.bytesize,
      omitted_bytes: text.bytesize - (bytes * 2)
    }
  end

  def self.proposal_payload(proposal)
    {
      id: proposal.id,
      slug: proposal.slug,
      title: proposal.title,
      body: proposal.body,
      kind: proposal.kind,
      state: proposal.state,
      labels: labels_for(proposal),
      dependencies: proposal.dependencies.order(:slug).pluck(:slug)
    }
  end

  def self.repository_note_payload(note)
    {
      id: note.id,
      body: note.body,
      author: note.author,
      created_at: note.created_at.iso8601
    }
  end

  def self.labels_for(proposal)
    raw = proposal.labels
    return [] if raw.blank?
    return raw if raw.is_a?(Array)

    JSON.parse(raw)
  rescue JSON::ParserError
    Array(raw)
  end

  def self.safe_byteslice(text, start, length)
    text.byteslice(start, length).to_s.encode("UTF-8", invalid: :replace, undef: :replace)
  end
end
