# Proposal-editing helpers extracted from Api::V1::App::ChatsController.
#
# Backing the update_proposal action: strong params, rebuilding a proposal's
# dependency edges from a slug list, validating referenced job/epic ids, and
# the compact proposal search JSON. They operate on the passed chat session /
# proposal (no per-user scoping of their own), so they mix straight back in
# with no behavior change. Kept private on include.
#
# The app-event broadcast after an edit is NOT here: Api::V1::App::ChatsController
# defines its own broadcast_proposal_updated directly (richer payload --
# serialized proposal, job_status_proposal, pending_proposal_count -- fanned
# out to every participant), which shadows a same-named method defined in an
# included module. Don't reintroduce one here; it would silently never run.
module ChatProposalMutation
  private

  def proposal_update_params
    params.require(:proposal).permit(:title, :body, :route_to_backlog, dependency_slugs: [], depends_on_job_ids: [], depends_on_epic_ids: [], media_ids: [])
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
end
