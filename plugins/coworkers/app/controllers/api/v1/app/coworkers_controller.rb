module Api
  module V1
    module App
      class CoworkersController < BaseController
        include ChatProviderOptions
        include AgentProviderCatalogOptions

        def index
          coworkers = scope.includes(avatar_attachment: :blob).order(Arel.sql("LOWER(name) ASC"), :id).to_a
          weekly_spend = Coworkers::Activity.weekly_spend_by_coworker(
            coworkers: coworkers, user: Current.user
          )
          render json: {
            coworkers: coworkers.map { |coworker| summary_json(coworker, weekly_spend_usd: weekly_spend.fetch(coworker.id)) },
            syrus: syrus_json,
            model_options: model_options_json,
            provisioning_attempts: Coworkers::ProvisioningAttempt.where(owner_user: Current.user)
              .where.not(state: "completed").order(updated_at: :desc).limit(25).map(&:public_status),
            grant_catalog: grant_catalog_json
          }
        end

        def show
          coworker = find_coworker
          render json: { coworker: detail_json(coworker) }
        end

        def create
          coworker = Coworkers::Coworker.new(owner_user: Current.user)
          authorize coworker, :create?, policy_class: CoworkerPolicy
          created = Coworkers::Create.call(owner: Current.user, idempotency_key: request.headers["Idempotency-Key"] || params[:idempotency_key],
            **create_params.to_h.symbolize_keys, avatar: params[:avatar], grants: requested_grants)
          render json: { coworker: detail_json(created), redirect_to: "/coworkers/#{created.id}" }, status: :created
        rescue ActiveRecord::RecordInvalid => error
          render_error("validation_failed", error.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        rescue Coworkers::Create::InvalidRemote, Coworkers::Create::BranchExists, ArgumentError => error
          render_error("validation_failed", error.message, status: :unprocessable_content)
        rescue Coworkers::Create::CreationFailed => error
          render_error(error.outcome.to_s, error.message, status: error.outcome == :cleanup_pending ? :accepted : :unprocessable_content)
        end

        def retry_provisioning_cleanup
          attempt = provisioning_attempt
          Coworkers::ProvisioningCleanupJob.perform_later(attempt.id)
          render json: { provisioning_attempt: attempt.public_status }, status: :accepted
        end

        def acknowledge_provisioning_cleanup
          attempt = provisioning_attempt
          unless attempt.state == "manual_attention"
            return render_error("invalid_state", "only manual-attention cleanup can be acknowledged", status: :unprocessable_content)
          end
          attempt.update!(acknowledged_at: Time.current, acknowledged_by: Current.user)
          render json: { provisioning_attempt: attempt.public_status }
        end

        def update
          coworker = find_coworker
          authorize coworker, :update?, policy_class: CoworkerPolicy
          Coworkers::BranchLifecycle.new(coworker).rename!(handle: params.require(:handle))
          render json: { coworker: detail_json(coworker.reload) }
        rescue Coworkers::OperationLock::Busy => error
          render_error("coworker_busy", error.message, status: :conflict)
        rescue ActiveRecord::RecordInvalid, ArgumentError => error
          render_error("validation_failed", error.message, status: :unprocessable_content)
        end

        def destroy
          coworker = find_coworker
          authorize coworker, :destroy?, policy_class: CoworkerPolicy
          branch = Coworkers::BranchLifecycle.new(coworker).archive!
          render json: { archived_branch: branch }
        rescue Coworkers::OperationLock::Busy => error
          render_error("coworker_busy", error.message, status: :conflict)
        end

        def update_grant
          coworker = find_coworker
          authorize coworker, :manage_grants?, policy_class: CoworkerPolicy
          Coworkers::GrantUpdate.call(
            owner: Current.user, coworker: coworker, capability: params[:capability],
            approval_policy: params.require(:approval_policy), constraints: grant_constraints, **grant_scope_argument,
            confirmed: params[:confirmed]
          )
          render json: { coworker: detail_json(coworker.reload) }
        rescue Coworkers::GrantUpdate::ConfirmationRequired => error
          render_error("confirmation_required", error.message, status: :conflict)
        rescue ActiveRecord::RecordInvalid, ArgumentError, KeyError => error
          render_error("validation_failed", error.message, status: :unprocessable_content)
        end

        def create_chat
          coworker = find_coworker
          authorize coworker, :manage_chats?, policy_class: CoworkerPolicy
          chat = ApplicationRecord.transaction do
            session = ChatSession.create!(
              user: Current.user, repository: workspace_repository(coworker), title: coworker.name,
              **coworker.chat_configuration
            )
            Coworkers::Chat.create!(coworker: coworker, chat_session: session, role: "side")
            session
          end
          render json: { chat_path: "/chats/#{chat.id}" }, status: :created
        end

        def add_to_chat
          chat = owned_chat
          coworker = find_coworker
          entry = Coworkers::ChatAgent.create_or_find_by!(chat_session: chat, coworker: coworker) do |agent|
            agent.added_by_user = Current.user
          end
          render json: { agent: roster_json(entry) }, status: :created
        rescue ActiveRecord::RecordInvalid => error
          render_error("validation_failed", error.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        def remove_from_chat
          entry = Coworkers::ChatAgent.find_by!(chat_session: owned_chat, coworker: find_coworker)
          entry.destroy!
          head :no_content
        end

        def memory
          coworker = find_coworker
          authorize coworker, :show?, policy_class: CoworkerPolicy
          begin
            payload = Coworkers::MemoryBrowser.new(
              coworker: coworker, repository: workspace_repository(coworker), user: Current.user
            ).call(search: params[:search])
            render json: payload
          rescue ActiveRecord::RecordNotFound, RepositoryContent::Unavailable, RepositoryContent::UnknownRevision => error
            Rails.logger.info("[Coworkers::MemoryBrowser] memory unavailable: #{error.class}: #{error.message}")
            render_error("remote_unavailable", I18n.t("api.coworkers.memory_unavailable"), status: :service_unavailable)
          end
        end

        def workspace
          coworker = find_coworker
          authorize coworker, :show?, policy_class: CoworkerPolicy
          payload = Coworkers::WorkspaceBrowser.new(
            coworker: coworker, repository: workspace_repository(coworker), user: Current.user
          ).call(path: params[:path])
          render json: payload
        rescue ActiveRecord::RecordNotFound, RepositoryContent::Unavailable, RepositoryContent::UnknownRevision => error
          Rails.logger.info("[Coworkers::WorkspaceBrowser] workspace unavailable: #{error.class}: #{error.message}")
          render_error("remote_unavailable", I18n.t("api.coworkers.memory_unavailable"), status: :service_unavailable)
        end

        def activity
          coworker = find_coworker
          authorize coworker, :show?, policy_class: CoworkerPolicy
          render json: Coworkers::Activity.new(coworker: coworker, user: Current.user).call
        end

        def approvals
          coworker = find_coworker
          authorize coworker, :show?, policy_class: CoworkerPolicy
          render json: { approvals: Coworkers::PendingApprovals.new(owner: Current.user, coworker: coworker).relation.map { |action| approval_json(action, coworker:) } }
        end

        def approve
          action = find_approval
          if action.enqueue_confirmation!(user: Current.user)
            render json: { approval: approval_json(action.reload, coworker: find_coworker) }, status: :accepted
          else
            render_error("approval_inactive", I18n.t("api.coworkers.approval_inactive"), status: :unprocessable_content)
          end
        rescue ActiveRecord::RecordInvalid, ArgumentError => error
          render_error("approval_expired", error.message, status: :unprocessable_content)
        end

        def reject
          action = find_approval
          if action.reject!(user: Current.user)
            render json: { approval: approval_json(action.reload, coworker: find_coworker) }
          else
            render_error("approval_inactive", I18n.t("api.coworkers.approval_inactive"), status: :unprocessable_content)
          end
        end

        def create_schedule
          coworker = find_coworker
          authorize coworker, :update?, policy_class: CoworkerPolicy
          repository = workspace_repository(coworker)
          return unless authorize_repository_write!(repository)

          task = coworker.schedules.new(
            schedule_params.merge(
              user: Current.user, repository: repository,
              pr_pileup_policy: "skip", auto_approve_mode: "never",
              after_run: schedule_params[:after_run].presence || "wake"
            )
          )
          if task.save
            render json: { schedule: schedule_json(task) }, status: :created
          else
            render_error("validation_failed", task.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def pause_schedule
          task = find_schedule
          return unless task
          return render_error("not_pausable", "Only an enabled task can be paused.", status: :unprocessable_content) unless task.active?

          task.pause!(reason: "operator")
          render json: { schedule: schedule_json(task.reload) }
        end

        def resume_schedule
          task = find_schedule
          return unless task
          return render_error("not_resumable", "A fired one-shot task cannot be resumed.", status: :unprocessable_content) if task.fired?

          task.resume!
          render json: { schedule: schedule_json(task.reload) }
        end

        def fire_schedule
          task = find_schedule
          return unless task

          result = ScheduledTasks::Fire.new(task).call
          render json: { schedule: schedule_json(task.reload), fired: result.fired?, reason: result.reason, job_id: result.job&.id }
        end
        def test_remote
          match = params.require(:workspace_repo).to_s.strip.match(%r{\A(?:https://github\.com/|git@github\.com:)([^/]+)/([^/]+?)(?:\.git)?/?\z}i)
          return render_error("validation_failed", I18n.t("api.coworkers.invalid_workspace_remote"), status: :unprocessable_content) unless match

          Coworkers::RemoteWorkspace.new(owner: match[1], name: match[2], user: Current.user).test_push_access!
          render json: { message: I18n.t("api.coworkers.push_access_verified") }
        rescue StandardError => error
          render_error("remote_unavailable", error.message, status: :unprocessable_content)
        end

        def sidebar_badge
          render json: { count: Coworkers::PendingApprovals.new(owner: Current.user).count }
        end

        private

        def provisioning_attempt
          Coworkers::ProvisioningAttempt.where(owner_user: Current.user).find(params[:attempt_id])
        end

        def scope = CoworkerPolicy::Scope.new(Current.user, Coworkers::Coworker.all).resolve

        def find_coworker
          scope.includes(:grants, coworker_chats: :chat_session).find(params[:id])
        end

        def owned_chat
          ChatSession.active.find_by!(id: params[:chat_id], user_id: Current.user.id)
        end

        def find_approval
          coworker = find_coworker
          authorize coworker, :show?, policy_class: CoworkerPolicy
          Coworkers::PendingApprovals.new(owner: Current.user, coworker: coworker).relation.find(params[:approval_id])
        end

        def approval_json(action, coworker:)
          {
            id: action.id, tool_name: action.payload["tool_name"], tool_input: action.payload["arguments"],
            run_id: action.payload["run_id"], chat_id: action.chat_session_id,
            created_at: action.created_at.iso8601, state: action.state,
            actor: {
              name: coworker.name, handle: coworker.handle, avatar_key: coworker.avatar_key,
              avatar_url: coworker.avatar_url, accent_hex: coworker.accent_hex
            }
          }
        end

        def roster_json(entry)
          coworker = entry.coworker
          { id: coworker.id, name: coworker.name, handle: coworker.handle, accent_hex: coworker.accent_hex,
            avatar_key: coworker.avatar_key, avatar_url: coworker.avatar_url, removable: true }
        end

        def create_params
          params.permit(:name, :handle, :workspace_repo, :about, :accent_hex, :avatar_key, :chat_provider, :chat_model, :chat_effort)
        end

        def grant_constraints
          params.permit(constraints: { confirm_paths: [] })[:constraints]&.to_h || {}
        end

        def grant_scope_argument
          params.key?(:scope) ? { scope: params[:scope] } : {}
        end

        def requested_grants
          return unless params.key?(:grants)
          scopes = params[:grant_scopes].respond_to?(:to_unsafe_h) ? params[:grant_scopes].to_unsafe_h : params[:grant_scopes].to_h
          Array(params[:grants]).map do |raw|
            if raw.respond_to?(:to_unsafe_h) || raw.respond_to?(:to_h)
              attributes = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
              { capability: attributes["capability"] || attributes[:capability], scope: attributes["scope"] || attributes[:scope] }
            else
              raw_scope = scopes[raw.to_s]
              { capability: raw, scope: raw_scope.present? ? JSON.parse(raw_scope) : nil }
            end
          end
        rescue JSON::ParserError
          raise ArgumentError, "invalid grant scope"
        end

        def grant_catalog_json
          defaults = Coworkers::Create::DEFAULT_GRANTS.keys.to_set
          Coworkers::GrantCatalog.all.map { |descriptor| descriptor.as_json(user: Current.user).merge(default_enabled: defaults.include?(descriptor.name)) }
        end

        def summary_json(coworker, weekly_spend_usd: nil)
          weekly_spend_usd ||= Coworkers::Activity.new(coworker: coworker, user: Current.user).week_spend
          {
            id: coworker.id, name: coworker.name, handle: coworker.handle, role_summary: coworker.role_summary,
            state: coworker.state, accent_hex: coworker.accent_hex, avatar_key: coworker.avatar_key,
            avatar_url: coworker.avatar_url, path: "/coworkers/#{coworker.id}",
            weekly_spend_usd: weekly_spend_usd
          }
        end

        def detail_json(coworker)
          summary_json(coworker).merge(
            chat_provider: coworker.chat_provider, chat_model: coworker.chat_model,
            effective_model: coworker.chat_model,
            workspace_repo: coworker.workspace_repo, soul: soul_for(coworker),
            available_chats: available_chats_json(coworker),
            chats: coworker.coworker_chats.sort_by { |link| [ link.main? ? 0 : 1, link.id ] }.map { |link| { id: link.chat_session_id, role: link.role, title: link.chat_session.title, path: "/chats/#{link.chat_session_id}" } },
            grants: coworker.grants.order(:capability).map { |grant|
              { capability: grant.capability, approval_policy: grant.approval_policy, constraints: grant.constraints }
                .merge(grant.scope.nil? ? {} : { scope: grant.scope })
            },
            grant_catalog: grant_catalog_json,
            schedules: coworker.schedules.alive.order(:created_at).map { |task| schedule_json(task) },
            message_traffic: message_traffic_json(coworker), spend_usd: spend_usd(coworker)
          )
        end

        def schedule_json(task)
          {
            id: task.id, name: task.name, prompt: task.prompt, kind: task.kind, state: task.state,
            after_run: task.after_run,
            schedule_input: task.schedule_input, schedule_explanation: task.schedule_explanation,
            fire_at: task.fire_at&.iso8601, next_fire_at: task.next_fire_at&.iso8601,
            last_fired_at: task.last_fired_at&.iso8601
          }
        end

        def schedule_params
          params.expect(schedule: %i[name prompt kind schedule_input cron_expression fire_at after_run])
        end

        def find_schedule
          coworker = find_coworker
          authorize coworker, :update?, policy_class: CoworkerPolicy
          task = coworker.schedules.alive.find(params[:schedule_id])
          return task if authorize_repository_write!(task.repository)

          nil
        end

        def spend_usd(coworker)
          chat_spend = coworker.coworker_chats.joins(:chat_session).sum("chat_sessions.cumulative_cost_usd")
          run_spend = Run.joins(:job).where(jobs: { origin: "coworkers", origin_id: coworker.id.to_s }).sum(:cost_usd)
          (chat_spend + run_spend).to_f
        end

        def message_traffic_json(coworker)
          main_chat = coworker.coworker_chats.find(&:main?)&.chat_session
          messages = main_chat ? main_chat.messages.active.where("created_at >= ?", 30.days.ago).to_a : []
          metadata = messages.filter_map { |message| message.content["coworker_message"] if message.content.is_a?(Hash) }
          delivered = metadata.select { |entry| entry["status"].blank? }
          events = messages.filter_map do |message|
            entry = message.content["coworker_message"] if message.content.is_a?(Hash)
            next unless entry&.fetch("status", nil).in?(%w[refused rate_limited])

            { status: entry.fetch("status"), receiver_handle: entry.fetch("receiver_handle"),
              reason: message.extract_text_from_content, occurred_at: message.created_at.iso8601 }
          end
          { sent: delivered.count { |entry| entry["direction"] == "outgoing" },
            received: delivered.count { |entry| entry["direction"] == "incoming" },
            window_days: 30, delivery_events: events.reverse.first(20) }
        end

        def soul_for(coworker)
          repository = workspace_repository(coworker)
          content = RepositoryContent.for(repository, user: Current.user)
          content.read_if_present(content.resolve("coworkers/#{coworker.handle}"), "SOUL.md")&.text
        rescue ActiveRecord::RecordNotFound, RepositoryContent::Error
          nil
        end

        def available_chats_json(coworker)
          chats = Current.user.chat_sessions.active.order(last_message_at: :desc, id: :desc).limit(100).to_a
          chat_ids = chats.map(&:id)
          rostered_ids = Coworkers::ChatAgent.where(coworker: coworker, chat_session_id: chat_ids).pluck(:chat_session_id).to_set
          own_chat_ids = Coworkers::Chat.where(coworker: coworker, chat_session_id: chat_ids).pluck(:chat_session_id).to_set

          chats.map do |chat|
            {
              id: chat.id, title: chat.title.presence || "Chat ##{chat.id}",
              rostered: rostered_ids.include?(chat.id), implicit: own_chat_ids.include?(chat.id)
            }
          end
        end

        def workspace_repository(coworker)
          match = coworker.workspace_repo.match(%r{github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?\z}i)
          raise ActiveRecord::RecordNotFound unless match

          Repository.where("LOWER(owner) = ? AND LOWER(name) = ?", match[1].downcase, match[2].downcase).first!
        end

        def syrus_json
          { id: "syrus", name: "Syrus", handle: "syrus", role_summary: "Engineer", state: "active", accent_hex: "#FBCFD3", avatar_key: nil, avatar_url: nil, path: "/coworkers/syrus", built_in: true, chat_model: nil }
        end

        def model_options_json
          agent_provider_catalog_options(Current.user).fetch(:agent_providers).filter_map do |provider|
            next unless provider.fetch(:configured)

            {
              provider: provider.fetch(:value),
              provider_label: provider.fetch(:label),
              models: provider.fetch(:models)
            }
          end
        end
      end
    end
  end
end
