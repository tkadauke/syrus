module ChatTemplates
  class Walkthrough
    USER_MESSAGE = "Give me a guided tour of this repository. Cover architecture, the main services, the dispatcher loop, and any non-obvious conventions. Cite file:line for everything.".freeze

    READING_LIST = %w[
      README.md
      ARCHITECTURE.md
      CLAUDE.md
      AGENTS.md
      db/schema.rb
      app/services
      app/jobs
    ].freeze

    def initialize(repository:)
      @repository = repository
    end

    def title
      "Guided tour of #{@repository.slug}"
    end

    def user_message
      USER_MESSAGE
    end

    def system_message
      <<~PROMPT
        This chat starts in repository walkthrough mode for #{@repository.slug}.

        Give the operator a guided tour of the repository. Be concrete,
        adapt to the conventions you actually find, and avoid assuming this
        is a Rails app, a Syrus repo, or a repo with complete documentation.

        Suggested first-pass reading list, when present:

        #{READING_LIST.map { |path| "- #{path}" }.join("\n")}

        Use the reading list as a hint, not a contract. If a file or directory
        is missing, say what you checked and move on. After the docs, inspect a
        few salient service and job/dispatcher files for the repo's actual
        runtime shape. Existing tools like `repo_info` and `list_jobs` can fill
        in repository metadata and prior Syrus activity, but cite file:line for
        claims about code structure and conventions.
      PROMPT
    end
  end
end
