module SyrusChatMcp
  HEAD_TAIL_BYTES = 4.kilobytes

  def self.success(payload)
    MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload) } ])
  end

  def self.invalid(reason)
    MCP::Tool::Response.new([ { type: "text", text: "Error: #{reason}" } ], error: true)
  end

  def self.unauthorized(message)
    MCP::Tool::Response.new([ { type: "text", text: "Unauthorized: #{message}" } ], error: true)
  end

  def self.not_authorized
    MCP::Tool::Response.new([ { type: "text", text: JSON.generate(error: "not_authorized") } ], error: true)
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
      dependencies: proposal.dependencies.order(:slug).pluck(:slug),
      repository: proposal.effective_repository&.slug,
      target_epic: target_epic_payload(proposal),
      materialized: materialized_payload(proposal)
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

  def self.materialized_payload(proposal)
    return { kind: "rejected", reason: proposal.state } if proposal.rejected? || proposal.withdrawn?

    case proposal.materialized_record
    when Job
      {
        kind: "job",
        job_id: proposal.job.id,
        job_title: proposal.job.issue_title,
        job_state: proposal.job.state
      }
    when Epic
      {
        kind: "epic",
        epic_id: proposal.epic.id,
        epic_title: proposal.epic.title,
        child_jobs: proposal.child_proposals.confirmed.includes(:job).map do |child|
          { job_id: child.job_id, title: child.job&.issue_title }
        end
      }
    end
  end

  def self.target_epic_payload(proposal)
    return unless proposal.target_epic

    { id: proposal.target_epic.id, number: proposal.target_epic.number, label: proposal.target_epic.display_number }
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
    text.to_s.safe_byteslice(start, length)
  end
end
