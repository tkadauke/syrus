class ChatEpicProposalDependencyWirer
  def initialize(user:)
    @user = user
  end

  def wire_for!(proposal)
    return unless proposal&.epic

    rewrite_resolved_tokens!(proposal)
    proposal.epic_dependency_tokens.each do |token|
      depends_on_epic = resolve_token(proposal, token)
      if depends_on_epic
        create_dependency!(proposal.epic, depends_on_epic)
      else
        create_pending_dependency!(proposal, token)
      end
    end
  end

  def resolve_confirmed_proposal!(confirmed_proposal)
    return unless confirmed_proposal&.epic

    resolve_pending_dependencies_on!(confirmed_proposal)

    slug = confirmed_proposal.slug
    epic_token = epic_token_for(confirmed_proposal.epic)

    confirmed_proposal.chat_session.proposals.where.not(id: confirmed_proposal.id).find_each do |proposal|
      tokens = proposal.epic_dependency_tokens
      next unless tokens.include?(slug)

      proposal.update!(epic_depends_on_tokens: JSON.generate(tokens.map { |token| token == slug ? epic_token : token }))
      next unless proposal.confirmed? && proposal.epic

      create_dependency!(proposal.epic, confirmed_proposal.epic)
    end
  end

  private

  # Holds the dependent Epic's admission open (via a pending EpicDependency
  # row -- see EpicDependency#pending?) while `token` names a sibling
  # proposal that exists but hasn't confirmed yet. Without this, a
  # depends_on_proposal_slugs token pointing at an unconfirmed proposal left
  # no trace at all, and Job admission (which only reacts to real
  # EpicDependency rows) had nothing to hold on -- ready child Jobs could
  # start and finish before the referenced proposal was ever confirmed.
  # A token with no matching proposal at all (forward reference to a slug
  # that doesn't exist yet, or a stale/rejected one) is left as-is, exactly
  # like before: #resolve_confirmed_proposal! still wires the dependency
  # retroactively once/if a matching proposal does confirm later.
  def create_pending_dependency!(proposal, token)
    return if token.to_s.match?(/\Aepic:\d+\z/)

    target_proposal = proposal.chat_session.proposals.find_by(slug: token)
    return unless target_proposal
    return if target_proposal.id == proposal.id
    return unless target_proposal.proposed?

    EpicDependency.find_or_create_by!(
      epic: proposal.epic,
      unresolved_chat_proposal: target_proposal
    )
  end

  def resolve_pending_dependencies_on!(confirmed_proposal)
    EpicDependency.pending.where(unresolved_chat_proposal: confirmed_proposal).find_each do |dependency|
      dependency.resolve!(depends_on_epic: confirmed_proposal.epic)
    end
  end

  attr_reader :user

  def rewrite_resolved_tokens!(proposal)
    rewritten = proposal.epic_dependency_tokens.map do |token|
      next token if token.match?(/\Aepic:\d+\z/)

      resolved = proposal.chat_session.proposals.confirmed.find_by(slug: token)&.epic
      resolved ? epic_token_for(resolved) : token
    end
    return if rewritten == proposal.epic_dependency_tokens

    proposal.update!(epic_depends_on_tokens: JSON.generate(rewritten))
  end

  def resolve_token(proposal, token)
    if token.to_s.match?(/\Aepic:\d+\z/)
      user.epics.find_by(id: token.split(":", 2).last)
    else
      proposal.chat_session.proposals.confirmed.find_by(slug: token)&.epic
    end
  end

  def epic_token_for(epic)
    "epic:#{epic.id}"
  end

  def create_dependency!(epic, depends_on_epic)
    return if epic.id == depends_on_epic.id

    ProposalDependencyValidator.validate!(depends_on_epic)
    EpicDependency.find_or_create_by!(
      epic: epic,
      depends_on_epic: depends_on_epic,
      derived: false
    )
  end
end
