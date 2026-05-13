module SyrusChatMcp
  def self.success(payload)
    MCP::Tool::Response.new([ { type: "text", text: JSON.generate(payload) } ])
  end

  def self.invalid(reason)
    MCP::Tool::Response.new([ { type: "text", text: "Error: #{reason}" } ], error: true)
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

  def self.labels_for(proposal)
    raw = proposal.labels
    return [] if raw.blank?
    return raw if raw.is_a?(Array)

    JSON.parse(raw)
  rescue JSON::ParserError
    Array(raw)
  end
end
