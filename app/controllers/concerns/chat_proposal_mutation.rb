# Proposal-editing helpers extracted from Api::V1::App::ChatsController.
#
# Backing the update_proposal action: strong params, rebuilding a proposal's
# dependency edges from a slug list, validating referenced job/epic ids, the
# compact proposal search JSON, and the app-event broadcast after an edit.
# They operate on the passed chat session / proposal (no per-user scoping of
# their own), so they mix straight back in with no behavior change. Kept
# private on include.
module ChatProposalMutation
  private

  def proposal_update_params
    params.require(:proposal).permit(:title, :body, :nonlinear_dependency_override, dependency_slugs: [], depends_on_job_ids: [], depends_on_epic_ids: [], media_ids: [])
  end

  def rebuild_proposal_dependencies!(chat_session, proposal, dependency_slugs)
    slugs = dependency_slugs.map(&:to_s).map(&:strip).reject(&:blank?).uniq
    dependencies = chat_session.proposals.where(slug: slugs).index_by(&:slug)
    missing = slugs - dependencies.keys
    raise ArgumentError, "Unknown proposal dependency: #{missing.first}" if missing.any?

    proposal.dependency_edges.destroy_all
    slugs.each do |slug|
      proposal.dependency_edges.create!(depends_on: dependencies.fetch(slug))
    end
  end

  def dependency_ids!(scope, raw_ids, name)
    ids = raw_ids.map(&:to_i).select(&:positive?).uniq
    found_ids = scope.where(id: ids).pluck(:id)
    missing = ids - found_ids
    raise ArgumentError, "Unknown #{name}: #{missing.first}" if missing.any?

    ids
  end

  def proposal_search_json(proposal)
    {
      id: proposal.id,
      slug: proposal.slug,
      title: proposal.title,
      state: proposal.state
    }
  end

  def broadcast_proposal_updated(chat_session, proposal)
    AppEvents.broadcast(
      user: chat_session.user,
      type: "updated",
      resource: "chat",
      id: chat_session.id,
      changed: [ "proposal" ],
      payload: {
        action: "update_proposal",
        proposal_id: proposal.id
      }
    )
  end
end
