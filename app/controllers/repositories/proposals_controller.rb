class Repositories::ProposalsController < ApplicationController
  before_action :load_repository
  before_action :load_proposal, only: %i[ update destroy file ]

  def index
    load_index
  end

  def update
    if @proposal.update(proposal_params)
      @proposal.reset_to_proposed_after_edit! unless @proposal.proposed?
      redirect_to repository_proposals_path(@repository), notice: "Proposal updated."
    else
      load_index
      @edit_proposal = @proposal
      flash.now[:alert] = "Proposal could not be updated."
      render :index, status: :unprocessable_content
    end
  end

  def destroy
    discarded = discard_scope

    ApplicationRecord.transaction do
      discarded.each do |proposal|
            proposal.update!(state: "withdrawn", discarded_at: Time.current, withdrawn_at: Time.current)
      end
      @proposal.dependent_edges.destroy_all unless cascade?
    end

    redirect_to repository_proposals_path(@repository),
                notice: "Withdrew #{helpers.pluralize(discarded.size, 'proposal')}."
  end

  def file
    if request.post?
      file_selected!([ @proposal ])
    else
      load_index
      load_file_preview([ @proposal ])
      render :index
    end
  end

  def file_bulk
    selected = selected_bulk_proposals
    if selected.empty?
      redirect_to repository_proposals_path(@repository), alert: "Select at least one proposal to file."
      return
    end

    if request.post?
      file_selected!(selected)
    else
      load_index
      load_file_preview(selected)
      render :index
    end
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
      scoped.where("chat_proposals.state = ? OR chat_proposals.updated_at >= ?", "proposed", 30.days.ago)
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
    ChatProposal
      .joins(chat_session: :chat_attachments)
      .where(chat_attachments: { attachable_type: "Repository", attachable_id: @repository.id })
  end

  def selected_bulk_proposals
    return proposals_scope.pending.order(:created_at, :id).to_a if params[:all].present?

    ids = Array(params[:proposal_ids]).compact_blank
    return [] if ids.empty?

    proposals_scope.pending.where(id: ids).order(:created_at, :id).to_a
  end

  def load_file_preview(selected)
    @file_selected_ids = selected.map(&:id)
    @file_all = params[:all].present?
    @file_proposals = ChatProposalFiler.ordered_closure(selected)
    @file_warnings = ChatProposalFiler.warnings_for(@file_proposals)
  end

  def file_selected!(selected)
    result = ChatProposalFiler.new(user: Current.user, repository: @repository).file!(selected)
    redirect_to repository_proposals_path(@repository), notice: file_notice(result)
  rescue ActiveRecord::RecordInvalid => e
    redirect_to repository_proposals_path(@repository), alert: "Could not file proposals: #{e.record.errors.full_messages.to_sentence}"
  end

  def file_notice(result)
    job_links = result.jobs.map { |job| helpers.link_to("Job ##{job.id}", job_path(job)) }
    epic_labels = result.epics.map(&:display_number)
    parts = [ "Filed #{helpers.pluralize(result.filed_count, 'proposal')}." ]
    parts << "Created #{helpers.pluralize(result.jobs.size, 'Job')}: #{job_links.to_sentence}." if job_links.any?
    parts << "Created #{helpers.pluralize(result.epics.size, 'Epic')}: #{epic_labels.to_sentence}." if epic_labels.any?
    parts << "GitHub issues will be picked up by polling." if result.github_issue_numbers.any?
    parts.join(" ").html_safe
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
