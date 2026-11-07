module Api
  module V1
    module App
      class EpicsController < BaseController
        PREVIEW_ATTENTION_PRIORITY = {
          "failed" => 0, "landing_failed" => 0, "blocked_by_epic" => 1, "triaging" => 2,
          "implemented" => 4, "approved" => 5, "landing" => 5, "merged" => 6,
          "closed" => 7, "preempted" => 7
        }.freeze
        before_action :authorize_epic_mutation!, only: %i[
          update archive claim unclaim reassign start update_state add_dependency remove_dependency unland_plan unland
        ]

        def index
          picker = params[:compact] == "picker"
          epics = policy_scope(Epic).includes(:repository)
          epics = epics.includes(:jobs) unless picker
          epics = epics.order(updated_at: :desc, id: :desc)
          epics = filter_epics(epics)
          limit = params.fetch(:limit, 20).to_i.clamp(1, 100)

          render json: {
            count: epics.count,
            epics: epics.limit(limit).map { |epic| picker ? picker_epic_json(epic) : compact_epic_json(epic) }
          }
        end

        def graph
          smart_folder = graph_smart_folder("epic")
          url_filter = Epics::Filter.from_params(params, user: Current.user)
          scope = Epics::Filter.from_params(
            params,
            smart_folder: url_filter.active? ? nil : smart_folder,
            user: Current.user
          ).apply(policy_scope(Epic))
          limit = params.fetch(:limit, 200).to_i.clamp(1, 200)
          offset = params.fetch(:offset, 0).to_i.clamp(0, 100_000)
          total_count = scope.count
          epic_attrs = scope.order(:id).limit(limit).offset(offset).pluck(:id, :title, :state, :number)
          epic_ids = epic_attrs.map(&:first)

          dependency_rows = if offset.zero?
            visible_ids = scope.reselect(:id)
            EpicDependency.where(epic_id: visible_ids, depends_on_epic_id: visible_ids).where.not(depends_on_epic_id: nil).pluck(:epic_id, :depends_on_epic_id)
          else
            []
          end

          nodes = epic_attrs.map do |id, title, state, number|
            {
              id: "epic_#{id}",
              kind: "epic",
              title: title.to_s,
              number: number,
              state: state.to_s,
              epic_id: id,
              is_focal: false
            }
          end

          edges = dependency_rows.map do |epic_id, depends_on_epic_id|
            { from_id: "epic_#{depends_on_epic_id}", to_id: "epic_#{epic_id}" }
          end

          render json: {
            nodes: nodes,
            edges: edges,
            pagination: { limit: limit, offset: offset, total_count: total_count, has_more: offset + epic_attrs.size < total_count }
          }
        end

        def show
          epic = find_epic
          render json: PerformanceLogging.phase("epic_detail_payload", epic_id: epic.id) { detail_payload(epic) }
        end

        def preview
          epic = find_epic
          jobs = visible_epic_jobs(epic).includes(:deployment_stage_statuses).order(:id).to_a
          preview_jobs = jobs.sort_by { |job| [ PREVIEW_ATTENTION_PRIORITY.fetch(job_summary_state(job), 3), job.id ] }.first(5)
          state_counts = jobs.each_with_object(Hash.new(0)) { |job, counts| counts[job_summary_state(job)] += 1 }
          deployment_stages_plan = RepoDeploymentStagesReader.for_repository(epic.repository)
          render json: {
            epic: {
              id: epic.id, display_number: epic.slug, title: epic.title.to_s,
              description: epic.description.to_s, state: epic.state,
              landing: epic.landing?, jobs_count: jobs.size,
              epic_path: epic_path(epic)
            },
            jobs: preview_jobs.map { |job| preview_job_json(job) },
            state_counts: state_counts,
            deployment_stages: epic_aggregate_deployment_stages(epic, jobs, deployment_stages_plan)
          }
        end

        def history
          epic = find_epic
          render json: {
            versions: epic.versions.includes(:user).order(created_at: :desc, id: :desc).map { |version| version_json(version) }
          }
        end

        def dependencies
          epic = find_epic
          graph = EpicDependencyGraphRenderer.new(epic).render
          render json: {
            graph: graph_json(graph),
            dependencies: epic.dependencies.where.not(depends_on_epic_id: nil).includes(depends_on_epic: :repository).order(:depends_on_epic_id).map { |dependency| dependency_epic_json(dependency.depends_on_epic) },
            dependents: epic.dependent_links.includes(epic: :repository).order(:epic_id).map { |dependency| dependency_epic_json(dependency.epic) }
          }
        end

        def job_metadata
          epic = find_epic
          jobs = visible_epic_jobs(epic).includes(:deployment_stage_statuses).order(:id).to_a
          plan = RepoDeploymentStagesReader.for_repository(epic.repository)
          payload = {
            provider_availability: preload_epic_job_provider_availability(jobs),
            jobs: jobs.map { |job| { id: job.id, deployment_stages: ::App::DeploymentStagesPayload.for_job(job, plan: plan) } }
          }
          stages = epic_aggregate_deployment_stages(epic, jobs, plan)
          payload[:deployment_stages] = stages if stages
          render json: payload
        end

        def new
          render_form_payload(Current.user.epics.new)
        end

        def edit
          render_form_payload(find_epic)
        end

        def create
          attrs = epic_params
          attrs = resolve_repository_reference(attrs)
          if attrs[:repository_id].present?
            return render_error("forbidden", I18n.t("api.epics.access_forbidden"), status: :forbidden) unless membership_on_repo?(attrs[:repository_id])
          end

          epic = Current.user.epics.new(attrs)
          start_requested = ActiveModel::Type::Boolean.new.cast(params[:start])

          if epic.save
            Metrics::ProductUsage.record(:epic_created)
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
          attrs = resolve_repository_reference(attrs)

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

          render json: mutation_payload(epic.reload, message: message)
        end

        def claim
          epic = find_epic

          epic.with_lock do
            return render_epic_already_owned(epic) if epic.owner_user_id.present?

            epic.owner_user = Current.user
            epic.claim!(Current.user)
            epic.claim_unowned_child_jobs!(Current.user)
          end

          render json: mutation_payload(epic.reload, message: I18n.t("api.epics.claimed"))
        rescue ArgumentError => e
          render_error("claim_not_allowed", e.message, status: :unprocessable_content)
        end

        def unclaim
          epic = find_epic
          return render_error("epic_not_owned", I18n.t("api.epics.not_claimed"), status: :unprocessable_content) if epic.owner_user_id.blank? && !epic.claimed?

          unless EpicPolicy.new(Current.user, epic).unclaim?
            return render_error("forbidden", I18n.t("api.epics.unclaim_forbidden"), status: :forbidden)
          end

          epic.with_lock do
            return render_epic_ownership_changed(epic) if epic.owner_user_id.blank? && !epic.claimed?

            epic.unclaim!(claimant: Current.user, force: Current.user.admin? || epic.owner_id.blank?)
          end

          render json: mutation_payload(epic.reload, message: I18n.t("api.epics.unclaimed"))
        rescue ArgumentError => e
          render_error("unclaim_not_allowed", e.message, status: :unprocessable_content)
        end

        def reassign
          epic = find_epic
          owner_param = params[:owner_user_id].presence || params[:owner_id].presence
          unless EpicPolicy.new(Current.user, epic).reassign?(via_owner_user_id_param: params[:owner_user_id].present?)
            return render_error("forbidden", I18n.t("api.epics.admin_forbidden"), status: :forbidden)
          end

          owner = User.find_by(id: owner_param)
          return render_error("owner_not_found", I18n.t("api.epics.owner_not_found"), status: :not_found) unless owner
          return unless authorize_epic_repository_write!(epic.repository, user: owner)

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

          render json: mutation_payload(epic.reload, message: I18n.t("api.epics.reassigned"))
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
          epic.reload.start_released_child_workflows_if_ready!

          render json: mutation_payload(epic.reload, message: I18n.t("api.epics.started"))
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
          epic.reload.start_released_child_workflows_if_ready! if params[:target_state].to_s == "in_progress"

          render json: mutation_payload(epic.reload, message: I18n.t("api.epics.updated"))
        rescue ArgumentError
          render_error("unknown_state", I18n.t("api.epics.unknown_state"), status: :unprocessable_content)
        rescue UnavailableTransition
          render_error("transition_not_allowed", I18n.t("api.epics.transition_not_allowed"), status: :unprocessable_content)
        end

        def unland_plan
          render json: Unlanding::Create.plan!(original: find_epic, user: Current.user).to_h
        rescue Unlanding::Eligibility::Disabled => e
          render_error("unland_disabled", e.message, status: :unprocessable_content)
        rescue Unlanding::Create::Ineligible => e
          render_error("unland_ineligible", e.message, status: :unprocessable_content)
        end

        def unland
          rollback = Unlanding::Create.call!(original: find_epic, user: Current.user)
          render json: {
            message: I18n.t("api.epics.unland_started", rollback: rollback.slug),
            rollback_job_id: rollback.id,
            rollback_job_slug: rollback.slug,
            rollback_job_path: job_path(rollback)
          }, status: :created
        rescue Unlanding::Eligibility::Disabled => e
          render_error("unland_disabled", e.message, status: :unprocessable_content)
        rescue Unlanding::Create::Ineligible => e
          render_error("unland_ineligible", e.message, status: :unprocessable_content)
        end

        def add_dependency
          epic = find_epic
          depends_on_epic = policy_scope(Epic).find(params.require(:depends_on_epic_id))
          return unless authorize_epic_repository_write!(depends_on_epic.repository)

          dependency = epic.dependencies.build(depends_on_epic: depends_on_epic)

          if dependency.save
            render json: mutation_payload(epic.reload, message: I18n.t("api.epics.dependency_added"))
          else
            render_error("validation_failed", dependency.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def remove_dependency
          epic = find_epic
          epic.dependencies.where(depends_on_epic_id: params[:depends_on_epic_id]).destroy_all

          render json: mutation_payload(epic.reload, message: I18n.t("api.epics.dependency_removed"))
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
          jobs = visible_epic_jobs(epic).to_a
          {
            id: epic.id,
            number: epic.number,
            title: epic.title.to_s,
            state: epic.state,
            repository_slug: epic.repository.slug,
            goal_provenance: ::App::GoalProvenancePayload.for(epic),
            done_jobs_count: done_jobs_count(jobs),
            total_jobs_count: jobs.size,
            updated_at: epic.updated_at&.iso8601,
            max_commits_behind_base: jobs.select { |j| j.parent_job_id.nil? }.filter_map(&:commits_behind_base).max
          }
        end

        def picker_epic_json(epic)
          { id: epic.id, number: epic.number, title: epic.title.to_s, state: epic.state, repository_slug: epic.repository.slug }
        end

        def preview_job_json(job)
          { id: job.id, title: job.issue_title.to_s, state: job_summary_state(job) }
        end

        class UnavailableTransition < StandardError; end

        def form_payload(epic, accessible_repos: Repository.writable_by(Current.user).active.order(:owner, :name))
          {
            epic: epic_json(epic),
            repositories: accessible_repos.map { |repository| repository_json(repository) },
            dashboard_epics_path: dashboard_epics_path
          }
        end

        def render_form_payload(epic)
          repositories = Repository.writable_by(Current.user).active.order(:owner, :name).to_a
          etag = [ "epic-form", Current.user.cache_key_with_version, epic.cache_key_with_version, repositories.map(&:cache_key_with_version) ]
          return unless stale?(etag: etag, public: false)

          render json: form_payload(epic, accessible_repos: repositories)
        end

        def detail_payload(epic, message: nil)
          jobs = PerformanceLogging.phase("epic_detail.jobs", epic_id: epic.id) do
            unordered_jobs = visible_epic_jobs(epic)
                                 .with_latest_workflow_snapshot
                                 .includes(:repository, :owner_user, :dependencies, :dependent_links)
                                 .order(:id)
                                 .to_a
            order_jobs_by_chain(unordered_jobs)
          end
          blocked_dependency = PerformanceLogging.phase("epic_detail.blocked_dependency", epic_id: epic.id) do
            epic.dependencies.includes(:depends_on_epic, :depends_on_job).find { |dependency| !dependency.dependency_succeeded? }
          end
          active_train = PerformanceLogging.phase("epic_detail.active_merge_train", epic_id: epic.id) do
            MergeTrain.active.where(epic_id: epic.id).where.not(integration_branch: nil).order(:id).last
          end

          payload = {
            message: message,
            merge_train_branch: active_train&.integration_branch,
            merge_train_status: PerformanceLogging.phase("epic_detail.merge_train_status", epic_id: epic.id) { ::App::MergeTrainStatus.for_epic(epic) },
            origin_chat: PerformanceLogging.phase("epic_detail.origin_chat", epic_id: epic.id) { epic_origin_chat_json(epic) },
            epic: PerformanceLogging.phase("epic_detail.epic", epic_id: epic.id) { detail_epic_json(epic, jobs: jobs) },
            unland: unland_json(epic),
            summary: {
              done_jobs_count: done_jobs_count(jobs),
              total_jobs_count: jobs.size,
              dependency_edge_count: epic.dependencies.size + epic.dependent_links.size,
              blocked: blocked_dependency.present?,
              blocked_reason: epic_blocked_reason(blocked_dependency),
            },
            state_transitions: PerformanceLogging.phase("epic_detail.state_transitions", epic_id: epic.id) do
              ::App::Presentation.epic_state_transition_options(epic).map do |label, target_state|
                {
                  label: label,
                  target_state: target_state,
                  confirm: target_state == "archived" ? "Archive this Epic?" : nil
                }
              end
            end,
            jobs: PerformanceLogging.phase("epic_detail.jobs.serialize", epic_id: epic.id, count: jobs.size) do
              jobs.map { |job| job_json(job) }
            end,
            paths: {
              dashboard_epics_path: dashboard_epics_path,
              edit_epic_path: edit_epic_path(epic),
              app_state_path: "/api/v1/app/epics/#{epic.id}/state",
              app_start_path: "/api/v1/app/epics/#{epic.id}/start",
              app_archive_path: "/api/v1/app/epics/#{epic.id}/archive",
              app_claim_path: "/api/v1/app/epics/#{epic.id}/claim",
              app_unclaim_path: "/api/v1/app/epics/#{epic.id}/unclaim",
              app_reassign_path: "/api/v1/app/epics/#{epic.id}/reassign",
              app_dependencies_path: "/api/v1/app/epics/#{epic.id}/dependencies",
              app_unland_path: Unlanding::Eligibility.enabled? ? "/api/v1/app/epics/#{epic.id}/unland" : nil
            }
          }

          payload
        end

        def mutation_payload(epic, message:)
          {
            message: message,
            epic: {
              id: epic.id, state: epic.state, archived: epic.archived?,
              startable: epic.may_start_implementing?(actor: Current.user), owner: owner_json(epic.owner),
              owner_user_id: epic.owner_user_id, owner_status: owner_status(epic),
              owner_user: owner_user_json(epic.owner_user),
              owned_by_current_user: epic.owner_user_id == Current.user.id || epic.claimed_by?(Current.user),
              claimable: epic.claimable?, claimed_at: epic.claimed_at&.iso8601,
              updated_at: epic.updated_at&.iso8601
            }
          }
        end

        def visible_epic_jobs(epic)
          Job.visible_to(Current.user, scope: epic.jobs)
        end

        def unland_json(epic)
          rollback = epic.rollback_jobs.order(created_at: :desc, id: :desc).first
          state = if epic.unlanded_by
            "reverted"
          elsif rollback&.failed?
            "failed"
          elsif rollback && !rollback.state.in?(Job::TERMINAL_STATES + %w[failed])
            "in_progress"
          elsif epic.done? && Unlanding::Eligibility.enabled?
            "landed"
          end
          { available: Unlanding::Eligibility.enabled?, state: state, rollback_job: rollback && { id: rollback.id, slug: rollback.slug, state: rollback.state, path: job_path(rollback), pr_number: rollback.pr_number, pr_url: rollback.pr_number && "https://github.com/#{rollback.repository.slug}/pull/#{rollback.pr_number}" } }
        end

        def epic_blocked_reason(dependency)
          return nil unless dependency

          if dependency.depends_on_job_id.present?
            job = dependency.depends_on_job
            return { key: "waiting_to_merge", params: { slug: job.slug } }
          end

          { key: "waiting_epic_to_complete", params: { number: dependency.depends_on_epic.number } }
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
            number: epic.number,
            display_number: epic.persisted? ? epic.slug : nil,
            title: epic.title.to_s,
            description: epic.description.to_s,
            owner_user_id: epic.owner_user_id,
            owner_status: owner_status(epic),
            owner_user: owner_user_json(epic.owner_user),
            repository_id: epic.repository_id,
            github_issue_url: epic.github_issue_url.to_s,
            epic_dependency_policy: epic.epic_dependency_policy,
            resolved_epic_dependency_policy: epic.resolved_epic_dependency_policy,
            goal_provenance: ::App::GoalProvenancePayload.for(epic),
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
            landing: epic.landing?(jobs: jobs),
            stuck: epic.stuck?,
            startable: epic.may_start_implementing?(actor: Current.user),
            can_unland: Unlanding::Eligibility.enabled? && EpicPolicy.new(Current.user, epic).write? && epic.done?,
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
            goal_provenance: ::App::GoalProvenancePayload.for(epic),
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

        # Displays child Jobs in implementation order (upstream dependency
        # first) rather than creation-id order, which drifts from the chain
        # whenever child issues aren't filed in ascending issue-number order.
        # Falls back to id order for jobs with no resolvable position in the
        # chain (nonlinear epics, dependencies outside the epic, ties).
        def order_jobs_by_chain(jobs)
          by_id = jobs.index_by(&:id)
          downstream_of = Hash.new { |h, k| h[k] = [] }
          incoming_count = by_id.transform_values { 0 }

          jobs.each do |job|
            job.dependencies.each do |dependency|
              next unless by_id.key?(dependency.depends_on_job_id)

              downstream_of[dependency.depends_on_job_id] << job.id
              incoming_count[job.id] += 1
            end
          end

          remaining = incoming_count.dup
          queue = by_id.keys.select { |id| remaining[id].zero? }.sort
          ordered_ids = []

          until queue.empty?
            id = queue.shift
            ordered_ids << id
            downstream_of[id].sort.each do |next_id|
              remaining[next_id] -= 1
              queue << next_id if remaining[next_id].zero?
            end
            queue.sort!
          end

          ordered_ids.concat(by_id.keys - ordered_ids)
          ordered_ids.map { |id| by_id.fetch(id) }
        end

        def job_json(job)
          label = if job.direct?
            "Direct"
          elsif job.issue_number.present?
            "##{job.issue_number}"
          else
            job.slug
          end

          result = {
            id: job.id,
            slug: job.slug,
            label: label,
            title: job.issue_title.to_s,
            path: job_path(job),
            state: job_summary_state(job),
            agent_provider: job.workflow_agent_provider,
            landed: job.landed_sha.present?,
            pr_number: job.pr_number,
            pr_url: ::App::Presentation.job_pr_url(job),
            owner_user_id: job.owner_user_id,
            owner_user: owner_user_json(job.owner_user),
            repository_slug: job.repository.slug
          }
          result
        end

        def preload_epic_job_provider_availability(jobs)
          @epic_job_provider_availability_by_provider = PerformanceLogging.phase("epic_detail.preload_provider_availability", count: jobs.size) do
            jobs.map(&:workflow_agent_provider).compact.uniq.index_with do |provider|
              ::App::ProviderAvailability.for_user(Current.user, provider)
            end
          end
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
          @epic ||= find_epic_by_ref(policy_scope(Epic).includes(:owner_user, :repository), params[:id])
        end

        def membership_on_repo?(repository_id)
          Repository.find_by(id: repository_id)&.member_at_least?(Current.user, "write") || false
        end

        def authorize_epic_repository_write!(repository, user: Current.user)
          return true if RepositoryPolicy.new(user, repository).write?

          render_error("forbidden", I18n.t("api.epics.access_forbidden"), status: :forbidden)
          false
        end

        def resolve_repository_reference(attrs)
          attrs = attrs.to_h.symbolize_keys
          slug = attrs.delete(:repository).presence || attrs.delete(:repo).presence
          return attrs if slug.blank? || attrs[:repository_id].present?

          owner, name = slug.to_s.split("/", 2)
          repository = Repository.active.find_by(owner: owner, name: name) if owner.present? && name.present?
          attrs[:repository_id] = repository&.id || 0
          attrs
        end

        # Best-effort start after a start=true create:
        # the Epic row is already saved, so a non-startable Epic (e.g. product
        # owner actor, empty Epic) degrades to a plain create instead of failing
        # the request.
        def start_created_epic!(epic)
          return false unless epic.may_start_implementing?(actor: Current.user)

          epic.start_implementing!(actor: Current.user)
          auto_claim_started_epic!(epic, "in_progress")
          true
        rescue Epic::NotStartable
          false
        end

        def authorize_epic_mutation!
          policy = EpicPolicy.new(Current.user, find_epic)
          unless policy.write?
            render_error("forbidden", I18n.t("api.epics.access_forbidden"), status: :forbidden)
            return false
          end

          return true unless action_name.in?(%w[start update_state])

          target_state = action_name == "start" ? "in_progress" : params[:target_state].to_s
          return true if policy.advance_state?(target_state: target_state)

          render_error(
            "forbidden",
            I18n.t("api.epics.product_owner_forbidden"),
            status: :forbidden
          )
          false
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

        def epic_aggregate_deployment_stages(epic, jobs, deployment_stages_plan)
          return nil unless epic.done?
          return nil if deployment_stages_plan.stages.empty?

          landed_jobs = jobs.select { |j| j.landed_sha.present? }
          return nil if landed_jobs.empty?

          deployment_stages_plan.stages.map do |stage|
            reached_statuses = landed_jobs.filter_map { |job|
              job.deployment_stage_statuses.find { |s| s.stage_name == stage.name }
            }
            {
              name: stage.name,
              label: stage.label,
              scope: stage.scope,
              reached_count: reached_statuses.count,
              total: landed_jobs.count,
              reached_at: reached_statuses.filter_map(&:reached_at).max&.iso8601
            }
          end
        end

        def epic_params
          params.require(:epic).permit(:title, :description, :repository_id, :repository, :repo, :github_issue_url, :epic_dependency_policy)
        end
      end
    end
  end
end
