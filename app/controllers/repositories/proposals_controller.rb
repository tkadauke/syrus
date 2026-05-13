class Repositories::ProposalsController < ApplicationController
  before_action :load_repository
  before_action :load_proposal, only: %i[ update destroy ]

  def index
    load_index
  end

  def update
    if @proposal.update(proposal_params)
      redirect_to repository_proposals_path(@repository), notice: "Proposal updated."
    else
      load_index
      @edit_proposal = @proposal
      flash.now[:alert] = "Proposal could not be updated."
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    discarded = discard_scope

    ApplicationRecord.transaction do
      discarded.each do |proposal|
        proposal.update!(state: "discarded", discarded_at: Time.current)
      end
      @proposal.dependent_edges.destroy_all unless cascade?
    end

    redirect_to repository_proposals_path(@repository),
                notice: "Discarded #{helpers.pluralize(discarded.size, 'proposal')}."
  end

  private

  def load_repository
    @repository = Current.user.repositories.find(params[:repository_id])
  end

  def load_proposal
    @proposal = proposals_scope.find(params[:id])
  end

  def proposal_params
    params.require(:chat_proposal).permit(:title, :body, :labels)
  end

  def load_index
    @include_resolved = ActiveModel::Type::Boolean.new.cast(params[:include_resolved])
    scoped = proposals_scope.includes(:dependencies, :dependents, :chat_session)
    scoped = if @include_resolved
      scoped.where("chat_proposals.state = ? OR chat_proposals.updated_at >= ?", "pending", 30.days.ago)
    else
      scoped.pending
    end

    ordered = ChatProposal.topological_sort(scoped.order(:created_at, :id))
    @proposal_layers = layered_proposals(ordered)
    @edit_proposal = find_visible_proposal(params[:edit_id], ordered)
    @discard_proposal = find_visible_proposal(params[:discard_id], ordered)
    @discard_downstream = downstream_for(@discard_proposal)
  end

  def proposals_scope
    ChatProposal.joins(:chat_session).where(chat_sessions: { repository_id: @repository.id })
  end

  def find_visible_proposal(id, ordered)
    return if id.blank?

    ordered.find { |proposal| proposal.id == id.to_i }
  end

  def layered_proposals(ordered)
    visible_ids = ordered.map(&:id).to_set
    layer_by_id = {}

    ordered.each do |proposal|
      dependency_layers = proposal.dependencies.select { |dep| visible_ids.include?(dep.id) }.map { |dep| layer_by_id.fetch(dep.id, 0) }
      layer = dependency_layers.empty? ? 0 : dependency_layers.max + 1
      layer_by_id[proposal.id] = layer
    end

    ordered.group_by { |proposal| layer_by_id.fetch(proposal.id, 0) }.sort.to_h
  end

  def downstream_for(proposal)
    return [] unless proposal

    ChatProposal.topological_sort(ChatProposal.transitive_downstream_closure([ proposal ]).to_a)
      .reject { |candidate| candidate.id == proposal.id }
  end

  def discard_scope
    if cascade?
      ChatProposal.topological_sort(ChatProposal.transitive_downstream_closure([ @proposal ]).to_a)
    else
      [ @proposal ]
    end
  end

  def cascade?
    params[:discard_mode] == "cascade"
  end
end
