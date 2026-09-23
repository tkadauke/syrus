module GithubSource
  class UiSlots
    include Syrus::Plugin::UiSlot
    include Rails.application.routes.url_helpers

    def self.ui_slots(slot:, context:)
      return [] unless slot == "dashboard.jobs.notice"

      new(context).ui_slots
    end

    def initialize(context)
      @context = context
    end

    def ui_slots
      return [] unless visible?

      repositories = active_repositories_scope.where("untagged_open_issue_count > 0")
      repositories_json = repositories.map { |repository| repository_json(repository) }
      total = repositories_json.sum { |entry| entry.fetch(:count) }
      return [] if total.zero?

      [
        {
          id: "github_source.untagged_issues",
          component: "github_source/UntaggedIssuesBanner",
          order: 10,
          props: {
            untagged_issues: {
              total: total,
              repositories: repositories_json
            }
          }
        }
      ]
    end

    private

    attr_reader :context

    def visible?
      context[:subject] == "job" &&
        context[:active_smart_folder]&.attention_preset == "inbox"
    end

    def active_repositories_scope
      context.fetch(:active_repositories_scope)
    end

    def repository_json(repository)
      {
        id: repository.id,
        slug: repository.slug,
        count: repository.untagged_open_issue_count,
        issues_path: "/repositories/#{repository.id}/plugin/issues"
      }
    end
  end
end
