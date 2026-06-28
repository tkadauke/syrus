class ChatEpicProposalDependencyWirer
  def initialize(user:)
    @user = user
  end

  def wire_for!(proposal)
    return unless proposal&.epic

    rewrite_resolved_tokens!(proposal)
    proposal.epic_dependency_tokens.each do |token|
      depends_on_epic = resolve_token(proposal, token)
      next unless depends_on_epic

      create_dependency!(proposal.epic, depends_on_epic)
    end
  end

  def resolve_confirmed_proposal!(confirmed_proposal)
    return unless confirmed_proposal&.epic

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

    EpicDependency.find_or_create_by!(
      epic: epic,
      depends_on_epic: depends_on_epic,
      derived: false
    )
  end
end
