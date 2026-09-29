module Prompts
  # Prompt for a direct Job created directly by the operator with a
  # free-form prompt. Unlike issue Jobs (which fetch the title+body from
  # GitHub) or cron Jobs (which wrap a standing instruction in a preamble),
  # direct Jobs carry the operator's prompt as-is — just append the
  # standard safety and submit-summary footers.
  class DirectJob
    def initialize(prompt:, epic: nil, job: nil, user: nil, repository_ids: [])
      @prompt = prompt
      @epic = epic
      @job = job
      @user = user
      @repository_ids = repository_ids
    end

    def to_s
      [ @prompt.strip, planned_execution_context, epic_context, memory_context, GitSafety::TEXT, SubmitSummaryInstructions::TEXT ].compact_blank.join("\n\n")
    end

    private

    def epic_context
      Prompts::EpicContext.new(epic: @epic, job: @job).to_s
    end

    def planned_execution_context
      return unless @job

      planned = @job.planned_execution_json
      return if planned.dig("capabilities", "os") == [ "linux" ] && planned["source"] == "defaulted"

      <<~TEXT.strip
        Planned primary implementation placement:

        #{JSON.pretty_generate(planned)}
      TEXT
    end

    def memory_context
      Prompts::MemoryContext.new(user: @user, repository_ids: @repository_ids).to_s.presence
    end
  end
end
