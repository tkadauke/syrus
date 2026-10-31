module Coworkers
  class McpPresenter
    def initialize(coworker)
      @coworker = coworker
    end

    def summary
      main_chat = coworker.coworker_chats.find(&:main?)
      {
        id: coworker.id,
        name: coworker.name,
        handle: coworker.handle,
        role_summary: coworker.role_summary,
        state: coworker.state,
        appearance: {
          accent_hex: coworker.accent_hex,
          avatar_key: coworker.avatar_key,
          avatar_url: coworker.avatar_url
        }.compact,
        path: "/coworkers/#{coworker.id}",
        main_chat: chat_payload(main_chat)
      }
    end

    def detail
      summary.merge(
        model_configuration: {
          provider: configured_value(coworker.chat_provider, coworker.owner_user.effective_chat_provider),
          model: configured_value(coworker.chat_model),
          effort: configured_value(coworker.chat_effort)
        },
        workspace: {
          repository: safe_workspace_repository,
          home_branch: "coworkers/#{coworker.handle}"
        },
        grants: coworker.grants.sort_by(&:capability).map { |grant| grant_payload(grant) },
        chats: coworker.coworker_chats.sort_by { |link| [ link.main? ? 0 : 1, link.id ] }.map { |link| chat_payload(link) },
        active_schedules: coworker.schedules.active.order(:id).map { |task| schedule_payload(task) }
      )
    end

    private

    attr_reader :coworker

    def configured_value(value, default = nil)
      value.present? ? { value: value, source: "coworker" } : { value: default, source: "account_default" }
    end

    def grant_payload(grant)
      descriptor = Coworkers::GrantCatalog.fetch(grant.capability)
      { capability: grant.capability, approval_policy: grant.approval_policy, constraints: grant.constraints || {},
        scope: grant.scope, scope_label: grant.scope.present? ? descriptor.scope_label(grant.scope) : nil }
    end

    def safe_workspace_repository
      match = coworker.workspace_repo.match(
        %r{\A(?:https://(?:[^/@]+@)?github\.com/|git@github\.com:)([^/]+)/([^/]+?)(?:\.git)?/?\z}i
      )
      return unless match

      "https://github.com/#{match[1]}/#{match[2]}.git"
    end

    def chat_payload(link)
      return unless link

      { id: link.chat_session_id, role: link.role, title: link.chat_session.title, path: "/chats/#{link.chat_session_id}" }
    end

    def schedule_payload(task)
      {
        id: task.id, name: task.name, kind: task.kind, state: task.state,
        schedule: task.schedule_explanation,
        next_fire_at: task.next_fire_at&.iso8601
      }.compact
    end
  end
end
