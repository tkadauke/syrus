module Api
  module V1
    module App
      class EpicsController < BaseController
        def index
          epics = Current.user.epics.includes(:repository, :jobs).order(updated_at: :desc, id: :desc)
          if params[:repo].present?
            owner, name = params[:repo].to_s.split("/", 2)
            epics = epics.joins(:repository).where(repositories: { owner: owner, name: name })
          end
          limit = params.fetch(:limit, 20).to_i.clamp(1, 100)

          render json: {
            count: epics.count,
            epics: epics.limit(limit).map { |epic| compact_epic_json(epic) }
          }
        end

        def show
          render json: detail_payload(find_epic)
        end

        def new
          render json: form_payload(Current.user.epics.new)
        end

        def edit
          render json: form_payload(find_epic)
        end

        def create
          epic = Current.user.epics.new(epic_params)

          if epic.save
            render json: saved_payload(epic, message: "Epic created."), status: :created
          else
            render_error("validation_failed", epic.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def update
          epic = find_epic

          if epic.update(epic_params)
            render json: saved_payload(epic, message: "Epic updated.")
          else
            render_error("validation_failed", epic.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def archive
          epic = find_epic
          message = if epic.archived?
            "Epic already archived."
          else
            epic.archive!
            "Epic archived."
          end

          render json: detail_payload(epic.reload, message: message)
        end

        def claim
          epic = find_epic

          epic.with_lock do
            return render_epic_already_owned(epic) if epic.owner_user_id.present?

            epic.owner_user = Current.user
            epic.claim!(Current.user)
            epic.claim_unowned_child_jobs!(Current.user)
          end

          render json: detail_payload(epic.reload, message: "Epic claimed.")
        rescue ArgumentError => e
          render_error("claim_not_allowed", e.message, status: :unprocessable_content)
        end

        def unclaim
          epic = find_epic
          return render_error("epic_not_owned", "Epic is not claimed.", status: :unprocessable_content) if epic.owner_user_id.blank? && !epic.claimed?

          unless epic.owner_user_id == Current.user.id || Current.user.admin?
            return render_error("forbidden", "Only the owner or an admin can unclaim this Epic.", status: :forbidden)
          end

          epic.with_lock do
            return render_epic_ownership_changed(epic) if epic.owner_user_id.blank? && !epic.claimed?

            epic.unclaim!(claimant: Current.user, force: Current.user.admin? || epic.owner_id.blank?)
          end

          render json: detail_payload(epic.reload, message: "Epic unclaimed.")
        rescue ArgumentError => e
          render_error("unclaim_not_allowed", e.message, status: :unprocessable_content)
        end

        def reassign
          epic = find_epic
          owner_param = params[:owner_user_id].presence || params[:owner_id].presence
          return render_error("forbidden", "Admin access required.", status: :forbidden) if params[:owner_user_id].present? && !Current.user.admin?

          owner = User.find_by(id: owner_param)
          return render_error("owner_not_found", "Owner user not found.", status: :not_found) unless owner

          if epic.owner_user_id == owner.id
            return render_error(
              "epic_already_owned",
              "Epic is already assigned to #{owner.email_address}.",
              status: :conflict
            )
          end

          epic.with_lock do
            epic.reassign!(owner, actor: Current.user)
            epic.reassign_child_jobs_to_owner!(owner)
          end

          render json: detail_payload(epic.reload, message: "Epic reassigned.")
        rescue ActionController::ParameterMissing, ArgumentError => e
          render_error("reassign_not_allowed", e.message, status: :unprocessable_content)
        end

        def update_state
          epic = find_epic
          transition_epic_state!(
            epic,
            params[:target_state].to_s,
            override: ActiveModel::Type::Boolean.new.cast(params[:override])
          )

          render json: detail_payload(epic.reload, message: "Epic updated.")
        rescue ArgumentError
          render_error("unknown_state", "Unknown Epic state.", status: :unprocessable_content)
        rescue UnavailableTransition
          render_error("transition_not_allowed", "That Epic transition is not available.", status: :unprocessable_content)
        end

        private

        def compact_epic_json(epic)
          jobs = epic.jobs.to_a
          {
            id: epic.id,
            number: epic.number,
            title: epic.title.to_s,
            state: epic.state,
            repository_slug: epic.repository.slug,
            done_jobs_count: done_jobs_count(jobs),
            total_jobs_count: jobs.size,
            updated_at: epic.updated_at&.iso8601
          }
        end

        class UnavailableTransition < StandardError; end

        def form_payload(epic)
          {
            epic: epic_json(epic),
            repositories: Current.user.repositories.order(:name).map { |repository| repository_json(repository) },
            dashboard_epics_path: dashboard_epics_path
          }
        end

        def detail_payload(epic, message: nil)
          jobs = epic.jobs.includes(:repository, :dependencies, :dependent_links).order(:id).to_a
          blocked_dependency = epic.dependencies.includes(:depends_on_epic, :depends_on_job).find { |dependency| !dependency.dependency_succeeded? }
          graph = EpicDependencyGraphRenderer.new(epic).render

          {
            message: message,
            epic: detail_epic_json(epic, jobs: jobs),
            summary: {
              done_jobs_count: done_jobs_count(jobs),
              total_jobs_count: jobs.size,
              dependency_edge_count: epic.dependencies.size + epic.dependent_links.size,
              blocked: blocked_dependency.present?,
              blocked_reason: epic_blocked_reason(blocked_dependency)
            },
            state_transitions: ::App::Presentation.epic_state_transition_options(epic).map do |label, target_state|
              {
                label: label,
                target_state: target_state,
                confirm: target_state == "archived" ? "Archive this Epic?" : nil
              }
            end,
            graph: graph_json(graph),
            jobs: jobs.map { |job| job_json(job) },
            paths: {
              dashboard_epics_path: dashboard_epics_path,
              edit_epic_path: edit_epic_path(epic),
              app_state_path: "/api/v1/app/epics/#{epic.id}/state",
              app_archive_path: "/api/v1/app/epics/#{epic.id}/archive",
              app_claim_path: "/api/v1/app/epics/#{epic.id}/claim",
              app_unclaim_path: "/api/v1/app/epics/#{epic.id}/unclaim",
              app_reassign_path: "/api/v1/app/epics/#{epic.id}/reassign"
            }
          }
        end

        def epic_blocked_reason(dependency)
          return nil unless dependency

          if dependency.depends_on_job_id.present?
            job = dependency.depends_on_job
            return "waiting for Job ##{job.issue_number || job.id} to merge"
          end

          "waiting for Epic ##{dependency.depends_on_epic.number} to complete"
        end

        def saved_payload(epic, message:)
          {
            message: message,
            redirect_to: epic_path(epic),
            epic: epic_json(epic)
          }
        end

        def epic_json(epic)
          {
            id: epic.id,
            title: epic.title.to_s,
            description: epic.description.to_s,
            owner_user_id: epic.owner_user_id,
            owner_status: owner_status(epic),
            owner_user: owner_user_json(epic.owner_user),
            repository_id: epic.repository_id,
            github_issue_url: epic.github_issue_url.to_s,
            epic_path: epic.persisted? ? epic_path(epic) : nil
          }
        end

        def detail_epic_json(epic, jobs:)
          {
            id: epic.id,
            number: epic.number,
            display_number: epic.display_number,
            title: epic.title.to_s,
            description: epic.description.to_s,
            state: epic.state,
            owner: owner_json(epic.owner),
            owned_by_current_user: epic.owner_user_id == Current.user.id || epic.claimed_by?(Current.user),
            claimable: epic.claimable?,
            claimed_at: epic.claimed_at&.iso8601,
            github_issue_url: epic.github_issue_url.to_s,
            updated_at: epic.updated_at&.iso8601,
            archived: epic.archived?,
            jobs_count: jobs.size,
            epic_path: epic_path(epic),
            owner_user_id: epic.owner_user_id,
            owner_status: owner_status(epic),
            owner_user: owner_user_json(epic.owner_user),
            repository_slug: epic.repository.slug,
            repository: repository_json(epic.repository).merge(repository_path: repository_path(epic.repository))
          }
        end

        def owner_json(owner)
          return nil unless owner

          {
            id: owner.id,
            email_address: owner.email_address
          }
        end

        def graph_json(graph)
          {
            empty: graph.empty?,
            definition: graph.definition,
            node_count: graph.node_count,
            epic_dependency_count: graph.epic_dependency_count,
            job_blocker_count: graph.job_blocker_count,
            initially_open: graph.node_count <= 10
          }
        end

        def job_json(job)
          label = if job.direct?
            "Direct"
          elsif job.issue_number.present?
            "##{job.issue_number}"
          else
            ::App::Presentation.job_slug(job)
          end

          {
            id: job.id,
            label: label,
            title: job.issue_title.to_s,
            path: job_path(job),
            state: job_summary_state(job),
            pr_number: job.pr_number,
            pr_url: ::App::Presentation.job_pr_url(job),
            owner_user_id: job.owner_user_id,
            owner_user: owner_user_json(job.owner_user),
            repository_slug: job.repository.slug
          }
        end

        def repository_json(repository)
          {
            id: repository.id,
            slug: repository.slug
          }
        end

        def owner_status(epic)
          return "unclaimed" unless epic.claimed?
          return "mine" if epic.claimed_by?(Current.user)

          "other_owned"
        end

        def reassign_legacy_owner(epic)
          owner_user = User.find_by(id: params[:owner_id])
          return render_error("owner_not_found", "Owner user not found.", status: :not_found) unless owner_user

          epic.reassign!(owner_user, actor: Current.user)
          epic.update!(owner_user: owner_user) unless epic.owner_user_id == owner_user.id

          render json: detail_payload(epic.reload, message: "Epic reassigned.")
        end

        def owner_user_json(owner_user)
          return nil unless owner_user

          {
            id: owner_user.id,
            email_address: owner_user.email_address
          }
        end

        def render_epic_already_owned(epic)
          message = if epic.owner_user_id == Current.user.id
            "Epic is already claimed by you."
          else
            "Epic is already claimed by #{epic.owner_user&.email_address || "another user"}."
          end

          render_error("epic_already_owned", message, status: :conflict)
        end

        def render_epic_ownership_changed(epic)
          message = if epic.owner_user_id.blank?
            "Epic ownership changed before the request completed; it is now unclaimed."
          else
            "Epic ownership changed before the request completed; " \
              "it is now assigned to #{epic.owner_user&.email_address || "another user"}."
          end

          render_error("epic_ownership_changed", message, status: :conflict)
        end

        def find_epic
          Current.user.epics.includes(:owner_user).find(params[:id])
        end

        def transition_epic_state!(epic, target_state, override:)
          Epic.transaction do
            if override
              epic.override_state!(target_state)
            elsif epic.backlog? && target_state == "ready" && epic.may_auto_ready?
              epic.auto_ready!
            elsif epic.ready? && target_state == "backlog" && epic.may_move_to_backlog?
              epic.move_to_backlog!
            elsif epic.ready? && target_state == "in_progress"
              raise UnavailableTransition if epic.owner_id.present? && !epic.claimed_by?(Current.user)

              epic.claim!(Current.user) unless epic.claimed?
              epic.start!
            elsif epic.in_progress? && target_state == "ready"
              epic.unstart!
            elsif epic.in_progress? && target_state == "done" && epic.may_auto_complete?
              epic.auto_complete!
            elsif target_state == "archived" && epic.may_archive?
              epic.archive!
            elsif Epic::STATES.exclude?(target_state)
              raise ArgumentError, "unknown Epic state: #{target_state}"
            else
              raise UnavailableTransition
            end

            auto_claim_started_epic!(epic, target_state)
          end
        end

        def auto_claim_started_epic!(epic, target_state)
          return unless target_state == "in_progress"
          return unless epic.in_progress?

          if epic.owner_user_id == Current.user.id
            epic.claim_unowned_child_jobs!(Current.user)
            return
          end
          return if epic.owner_user_id.present?

          updated = Current.user.epics
                                .where(id: epic.id, owner_user_id: nil)
                                .update_all(owner_user_id: Current.user.id, updated_at: Time.current)
          return unless updated == 1

          epic.owner_user_id = Current.user.id
          epic.claim_unowned_child_jobs!(Current.user)
        end

        def done_jobs_count(jobs)
          jobs.count do |job|
            job.closed? && Epic::MERGED_JOB_CLOSURE_REASONS.include?(job.closure_reason)
          end
        end

        def job_summary_state(job)
          return "preempted" if job.closure_reason == "preempted"
          return "preempted" if job.closure_reason&.start_with?("external_pr_")

          job.state
        end

        def epic_params
          params.require(:epic).permit(:title, :description, :repository_id, :github_issue_url)
        end
      end
    end
  end
end
