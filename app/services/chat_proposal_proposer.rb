class ChatProposalProposer
  def initialize(chat_session:, allowed_kinds: ChatProposal.kinds.keys)
    @chat_session = chat_session
    @allowed_kinds = allowed_kinds.map(&:to_s)
  end

  def propose!(slug:, title:, body:, kind: "syrus_issue", labels: [], depends_on: [])
    slug = slug.to_s.strip
    title = title.to_s.strip
    body = body.to_s.strip
    kind = kind.to_s.presence || "syrus_issue"
    labels = normalize_string_list(labels)
    dependency_slugs = normalize_string_list(depends_on)

    raise ArgumentError, "slug is required" if slug.empty?
    raise ArgumentError, "title is required" if title.empty?
    raise ArgumentError, "body is required" if body.empty?
    raise ArgumentError, "kind must be #{@allowed_kinds.to_sentence(last_word_connector: ' or ')}" unless @allowed_kinds.include?(kind)

    proposals_by_slug = @chat_session.proposals.index_by(&:slug)
    unknown_slugs = dependency_slugs - proposals_by_slug.keys
    raise ArgumentError, "unknown depends_on slug(s): #{unknown_slugs.join(', ')}" if unknown_slugs.any?

    existing = proposals_by_slug[slug]
    proposal = existing || @chat_session.proposals.build(slug: slug)
    dependencies = dependency_slugs.map { |dependency_slug| proposals_by_slug.fetch(dependency_slug) }
    raise ArgumentError, "depends_on would create a cycle" if cycle?(proposal, dependencies)

    proposal.transaction do
      proposal.assign_attributes(title: title, body: body, kind: kind, labels: JSON.generate(labels))
      if existing
        proposal.state = "proposed"
        proposal.edited_at = Time.current
      end
      proposal.save!
      proposal.dependency_edges.destroy_all
      dependencies.each do |dependency|
        ChatProposalDependency.create!(proposal: proposal, depends_on: dependency)
      end
      @chat_session.messages.create!(
        role: "assistant",
        proposal: proposal,
        content: { "text" => existing ? "Proposal edited." : "Proposal proposed." }
      )
      @chat_session.update!(last_message_at: Time.current)
    end

    proposal
  end

  private

  def normalize_string_list(value)
    Array(value).map { |item| item.to_s.strip }.reject(&:empty?).uniq
  end

  def cycle?(proposal, dependencies)
    return false unless proposal.persisted?
    return true if dependencies.include?(proposal)

    dependencies.any? do |dependency|
      ChatProposal.transitive_upstream_closure([ dependency ]).include?(proposal)
    end
  end
end
