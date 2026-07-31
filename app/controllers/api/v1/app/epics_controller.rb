module Api
  module V1
    module App
      class EpicsController < BaseController
        before_action :authorize_epic_action!, only: [ :update_state, :start ]

        def index
          epics = Epic.accessible_to(Current.user).includes(:repository, :jobs).order(updated_at: :desc, id: :desc)
          epics = filter_epics(epics)
          limit = params.fetch(:limit, 20).to_i.clamp(1, 100)

          render json: {
            count: epics.count,
            epics: epics.limit(limit).map { |epic| compact_epic_json(epic) }
          }
        end

        def graph
          smart_folder = graph_smart_folder("epic")
          url_filter = Epics::Filter.from_params(params, user: Current.user)
          scope = Epics::Filter.from_params(
            params,
            smart_folder: url_filter.active? ? nil : smart_folder,
            user: Current.user
          ).apply(Epic.accessible_to(Current.user))
          epic_attrs = scope.pluck(:id, :title, :state, :number)
          epic_ids = epic_attrs.map(&:first)

          dependency_rows = EpicDependency
            .where(epic_id: epic_ids, depends_on_epic_id: epic_ids)
            .where.not(depends_on_epic_id: nil)
            .pluck(:epic_id, :depends_on_epic_id)

          nodes = epic_attrs.map do |id, title, state, number|
            slug = ::App::Presentation.epic_slug(number)
            {
              id: "epic_#{id}",
              kind: "epic",
              label: "#{slug} #{title}",
              state: state.to_s,
              epic_id: id,
              url: "/epics/#{slug}",
              is_focal: false
            }
          end

          edges = dependency_rows.map do |epic_id, depends_on_epic_id|
            { from_id: "epic_#{epic_id}", to_id: "epic_#{depends_on_epic_id}" }
          end

          render json: { nodes: nodes, edges: edges }
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
          start_requested = ActiveModel::Type::Boolean.new.cast(params[:start])

          if epic.save
            started = start_requested && start_created_epic!(epic)
            message = started ? I18n.t("api.epics.created_and_started") : I18n.t("api.epics.created")
            render json: saved_payload(epic, message: message), status: :created
          else
            render_error("validation_failed", epic.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def update
          epic = find_epic
          attrs = epic_params

          if attrs[:repository_id].present? && attrs[:repository_id].to_i != epic.repository_id
            return render_error("forbidden", I18n.t("api.epics.access_forbidden"), status: :forbidden) unless membership_on_repo?(attrs[:repository_id])
          end

          if epic.update(attrs)
            render json: saved_payload(epic, message: I18n.t("api.epics.updated"))
          else
            render_error("validation_failed", epic.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def archive
          epic = find_epic
          message = if epic.archived?
            I18n.t("api.epics.archived_already")
          else
            epic.archive!
            I18n.t("api.epics.archived")
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

          render json: detail_payload(epic.reload, message: I18n.t("api.epics.claimed"))
        rescue ArgumentError => e
          render_error("claim_not_allowed", e.message, status: :unprocessable_content)
        end

        def unclaim
          epic = find_epic
          return render_error("epic_not_owned", I18n.t("api.epics.not_claimed"), status: :unprocessable_content) if epic.owner_user_id.blank? && !epic.claimed?

          unless epic.owner_user_id == Current.user.id || Current.user.admin?
            return render_error("forbidden", I18n.t("api.epics.unclaim_forbidden"), status: :forbidden)
          end

          epic.with_lock do
            return render_epic_ownership_changed(epic) if epic.owner_user_id.blank? && !epic.claimed?

            epic.unclaim!(claimant: Current.user, force: Current.user.admin? || epic.owner_id.blank?)
          end

          render json: detail_payload(epic.reload, message: I18n.t("api.epics.unclaimed"))
        rescue ArgumentError => e
          render_error("unclaim_not_allowed", e.message, status: :unprocessable_content)
        end

        def reassign
          epic = find_epic
          owner_param = params[:owner_user_id].presence || params[:owner_id].presence
          return render_error("forbidden", I18n.t("api.epics.admin_forbidden"), status: :forbidden) if params[:owner_user_id].present? && !Current.user.admin?

          owner = User.find_by(id: owner_param)
          return render_error("owner_not_found", I18n.t("api.epics.owner_not_found"), status: :not_found) unless owner

          if epic.owner_user_id == owner.id
            return render_error(
              "epic_already_owned",
              I18n.t("api.epics.already_assigned", email: owner.email_address),
              status: :conflict
            )
          end

          epic.with_lock do
            epic.reassign!(owner, actor: Current.user)
            epic.reassign_child_jobs_to_owner!(owner)
          end

          render json: detail_payload(epic.reload, message: I18n.t("api.epics.reassigned"))
        rescue ActionController::ParameterMissing, ArgumentError => e
          render_error("reassign_not_allowed", e.message, status: :unprocessable_content)
        end

        # POST /api/v1/app/epics/:id/start — the explicit "Start implementing"
        # action: move the Epic into the In progress lane and release its held
        # child Jobs (dependency-gated children flow later as their gates close).
        def start
          epic = find_epic

          epic.with_lock do
            epic.start_implementing!(actor: Current.user)
            auto_claim_started_epic!(epic, "in_progress")
          end

          render json: detail_payload(epic.reload, message: I18n.t("api.epics.started"))
        rescue Epic::NotStartable => e
          render_error("epic_not_startable", e.message, status: :conflict)
        end

        def update_state
          epic = find_epic
          transition_epic_state!(
            epic,
            params[:target_state].to_s,
            override: ActiveModel::Type::Boolean.new.cast(params[:override])
          )

          render json: detail_payload(epic.reload, message: I18n.t("api.epics.updated"))
        rescue ArgumentError
          render_error("unknown_state", I18n.t("api.epics.unknown_state"), status: :unprocessable_content)
        rescue UnavailableTransition
          render_error("transition_not_allowed", I18n.t("api.epics.transition_not_allowed"), status: :unprocessable_content)
        end

        def add_dependency
          epic = find_epic
          depends_on_epic = Epic.accessible_to(Current.user).find(params.require(:depends_on_epic_id))
          dependency = epic.dependencies.build(depends_on_epic: depends_on_epic)

          if dependency.save
            render json: detail_payload(epic.reload, message: I18n.t("api.epics.dependency_added"))
          else
            render_error("validation_failed", dependency.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def remove_dependency
          epic = find_epic
          epic.dependencies.where(depends_on_epic_id: params[:depends_on_epic_id]).destroy_all

          render json: detail_payload(epic.reload, message: I18n.t("api.epics.dependency_removed"))
        end

        private

        def filter_epics(scope)
          if params[:repo].present?
            owner, name = params[:repo].to_s.split("/", 2)
            scope = scope.joins(:repository).where(repositories: { owner: owner, name: name })
          end
          if params[:q].present?
            pattern = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].to_s.downcase)}%"
            scope = scope.where("LOWER(title) LIKE :pattern OR CAST(epics.id AS CHAR) LIKE :pattern", pattern: pattern)
          end
          scope
        end

        def graph_smart_folder(subject_type)
          id = Integer(params[:smart_folder_id], exception: false)
          return unless id

          SmartFolder.for_subject(subject_type)
                     .where("user_id IS NULL OR user_id = ?", Current.user.id)
                     .find_by(id: id)
        end


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
            updated_at: epic.updated_at&.iso8601,
            max_commits_behind_base: jobs.select { |j| j.parent_job_id.nil? }.filter_map(&:commits_behind_base).max
          }
        end

        class UnavailableTransition < StandardError; end

        def form_payload(epic)
          accessible_repos = Repository.joins(:repository_memberships)
                                       .where(repository_memberships: { user: Current.user })
                                       .order(:name)
          {
            epic: epic_json(epic),
            repositories: accessible_repos.map { |repository| repository_json(repository) },
            dashboard_epics_path: dashboard_epics_path
          }
        end

        def detail_payload(epic, message: nil)
          jobs = epic.jobs.includes(:repository, :dependencies, :dependent_links).order(:id).to_a
          blocked_dependency = epic.dependencies.includes(:depends_on_epic, :depends_on_job).find { |dependency| !dependency.dependency_succeeded? }
          graph = EpicDependencyGraphRenderer.new(epic).render
          active_train = MergeTrain.active.where(epic_id: epic.id).where.not(integration_branch: nil).order(:id).last

          {
            message: message,
            merge_train_branch: active_train&.integration_branch,
            merge_train_status: ::App::MergeTrainStatus.for_epic(epic),
            origin_chat: epic_origin_chat_json(epic),
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
            dependencies: epic.dependencies.where.not(depends_on_epic_id: nil).includes(depends_on_epic: :repository).order(:depends_on_epic_id).map do |dependency|
              dependency_epic_json(dependency.depends_on_epic)
            end,
            dependents: epic.dependent_links.includes(epic: :repository).order(:epic_id).map do |dependency|
              dependency_epic_json(dependency.epic)
            end,
            jobs: jobs.map { |job| job_json(job) },
            versions: epic.versions.includes(:user).order(created_at: :desc, id: :desc).map { |version| version_json(version) },
            paths: {
              dashboard_epics_path: dashboard_epics_path,
              edit_epic_path: edit_epic_path(epic),
              app_state_path: "/api/v1/app/epics/#{epic.id}/state",
              app_start_path: "/api/v1/app/epics/#{epic.id}/start",
              app_archive_path: "/api/v1/app/epics/#{epic.id}/archive",
              app_claim_path: "/api/v1/app/epics/#{epic.id}/claim",
              app_unclaim_path: "/api/v1/app/epics/#{epic.id}/unclaim",
              app_reassign_path: "/api/v1/app/epics/#{epic.id}/reassign",
              app_dependencies_path: "/api/v1/app/epics/#{epic.id}/dependencies"
            }
          }
        end

        def epic_blocked_reason(dependency)
          return nil unless dependency

          if dependency.depends_on_job_id.present?
            job = dependency.depends_on_job
            return "waiting for #{job.slug} to merge"
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
            reconciliation_mode: epic.reconciliation_mode,
            epic_dependency_policy: epic.epic_dependency_policy,
            resolved_epic_dependency_policy: epic.resolved_epic_dependency_policy,
            epic_path: epic.persisted? ? epic_path(epic) : nil
          }
        end

        def detail_epic_json(epic, jobs:)
          furthest_behind = jobs.select { |j| j.parent_job_id.nil? && j.commits_behind_base.present? }
                               .max_by(&:commits_behind_base)
          {
            id: epic.id,
            number: epic.number,
            display_number: epic.slug,
            title: epic.title.to_s,
            description: epic.description.to_s,
            state: epic.state,
            stuck: epic.stuck?,
            startable: epic.may_start_implementing?(actor: Current.user),
            # Names of unfinished dependencies keeping a backlog/ready Epic
            # from being startable; the UI renders a muted "Waiting on ..."
            # hint in place of the hidden Start implementing button.
            start_blocked_on: (epic.backlog? || epic.ready?) ? epic.unfinished_dependency_names : [],
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
            repository: repository_json(epic.repository).merge(repository_path: repository_path(epic.repository)),
            epic_dependency_policy: epic.epic_dependency_policy,
            resolved_epic_dependency_policy: epic.resolved_epic_dependency_policy,
            max_commits_behind_base: furthest_behind&.commits_behind_base,
            furthest_behind_job_id: furthest_behind&.id,
            furthest_behind_job_path: furthest_behind ? job_path(furthest_behind) : nil
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
            node_count: graph.node_count,
            epic_dependency_count: graph.epic_dependency_count,
            job_blocker_count: graph.job_blocker_count,
            initially_open: graph.node_count <= 10,
            nodes: graph.nodes,
            edges: graph.edges
          }
        end

        def job_json(job)
          label = if job.direct?
            "Direct"
          elsif job.issue_number.present?
            "##{job.issue_number}"
          else
            job.slug
          end

          {
            id: job.id,
            slug: job.slug,
            label: label,
            title: job.issue_title.to_s,
            path: job_path(job),
            state: job_summary_state(job),
            agent_provider: job.agent_provider,
            provider_availability: ::App::ProviderAvailability.for_user(Current.user, job.agent_provider),
            pr_number: job.pr_number,
            pr_url: ::App::Presentation.job_pr_url(job),
            owner_user_id: job.owner_user_id,
            owner_user: owner_user_json(job.owner_user),
            repository_slug: job.repository.slug,
            branch_name: job.branch_name.to_s,
            depends_on_job_ids: job.dependencies.filter_map(&:depends_on_job_id)
          }
        end

        def repository_json(repository)
          {
            id: repository.id,
            slug: repository.slug,
            epic_dependency_policy: repository.epic_dependency_policy
          }
        end

        def dependency_epic_json(epic)
          {
            epic_id: epic.id,
            title: epic.title.to_s,
            state: epic.state,
            url: epic_path(epic)
          }
        end

        def version_json(version)
          {
            id: version.id,
            created_at: version.created_at.iso8601,
            actor: owner_user_json(version.user) || { email_address: "System" },
            title_before: version.title_before,
            title_after: version.title_after,
            description_before: version.description_before,
            description_after: version.description_after
          }
        end

        def owner_status(epic)
          return "unclaimed" unless epic.claimed?
          return "mine" if epic.claimed_by?(Current.user)

          "other_owned"
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
            I18n.t("api.epics.already_claimed_by_you")
          else
            I18n.t("api.epics.already_claimed", email: epic.owner_user&.email_address || I18n.t("api.epics.another_user"))
          end

          render_error("epic_already_owned", message, status: :conflict)
        end

        def render_epic_ownership_changed(epic)
          message = if epic.owner_user_id.blank?
            I18n.t("api.epics.ownership_changed_unclaimed")
          else
            I18n.t("api.epics.ownership_changed", email: epic.owner_user&.email_address || I18n.t("api.epics.another_user"))
          end

          render_error("epic_ownership_changed", message, status: :conflict)
        end

        def find_epic
          find_epic_by_ref(Epic.accessible_to(Current.user).includes(:owner_user), params[:id])
        end

        def membership_on_repo?(repository_id)
          RepositoryMembership.exists?(repository_id: repository_id, user: Current.user)
        end

        # Best-effort start after a "Create Epic & Start Implementing" create:
        # the Epic row is already saved, so a non-startable Epic (e.g. product
        # owner actor) degrades to a plain create instead of failing the request.
        def start_created_epic!(epic)
          return false unless epic.may_start_implementing?(actor: Current.user)

          epic.start_implementing!(actor: Current.user)
          auto_claim_started_epic!(epic, "in_progress")
          true
        rescue Epic::NotStartable
          false
        end

        def authorize_epic_action!
          return unless Current.user&.product_owner?

          target_state = action_name == "start" ? "in_progress" : params[:target_state].to_s
          return unless target_state.in?(%w[ready in_progress done])

          render_error(
            "forbidden",
            I18n.t("api.epics.product_owner_forbidden"),
            status: :forbidden
          )
        end

        def transition_epic_state!(epic, target_state, override:)
          Epic.transaction do
            if override
              epic.override_state!(target_state, actor: Current.user)
            elsif epic.backlog? && target_state == "ready" && epic.may_auto_ready?(actor: Current.user)
              epic.auto_ready!(actor: Current.user)
            elsif epic.ready? && target_state == "backlog" && epic.may_move_to_backlog?
              epic.move_to_backlog!
            elsif epic.ready? && target_state == "in_progress"
              raise UnavailableTransition if epic.owner_id.present? && !epic.claimed_by?(Current.user)

              epic.claim!(Current.user) unless epic.claimed?
              epic.start!(actor: Current.user)
            elsif epic.in_progress? && target_state == "ready"
              epic.unstart!
            elsif epic.in_progress? && target_state == "done" && epic.may_auto_complete?(actor: Current.user)
              epic.auto_complete!(actor: Current.user)
            elsif epic.in_progress? && target_state == "done" && epic.all_jobs_closed?
              epic.override_state!("done")
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
            job.closed? && Epic::SUCCESSFUL_JOB_CLOSURE_REASONS.include?(job.closure_reason)
          end
        end

        def job_summary_state(job)
          return "preempted" if job.closure_reason == "preempted"
          return "preempted" if job.closure_reason&.start_with?("external_pr_")

          job.state
        end

        def epic_origin_chat_json(epic)
          proposal = ChatProposal.where(epic_id: epic.id).order(:created_at, :id).first
          return unless proposal

          message = ChatMessage.where(proposal_id: proposal.id).order(:id).first
          return unless message

          {
            chat_session_id: proposal.chat_session_id,
            message_id: message.id
          }
        end

        def epic_params
          params.require(:epic).permit(:title, :description, :repository_id, :github_issue_url, :reconciliation_mode, :epic_dependency_policy)
        end
      end
    end
  end
end
