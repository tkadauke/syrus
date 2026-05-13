module ChatTemplates
  class Postmortem
    Result = Data.define(:title, :system_prompt, :user_message)

    def initialize(job:)
      @job = job
    end

    def render
      Result.new(
        title: "Postmortem Job ##{@job.id}",
        system_prompt: system_prompt,
        user_message: user_message
      )
    end

    private

    def system_prompt
      <<~PROMPT.strip
        For this conversation, act as a Job-failure analyst for Syrus.
        Your task is to explain why the target Job failed, grounded in
        evidence. Use read_job, list_jobs, read_pr, and shell inspection
        of the repository workspace as needed. Cite specific transcript
        lines, run logs, PR context, and code references. Distinguish
        observed facts from likely causes, and call out uncertainty.
      PROMPT
    end

    def user_message
      "Postmortem Job ##{@job.id}: #{job_title}. Why did this fail? Cite specific transcript lines and code."
    end

    def job_title
      @job.issue_title.to_s
    end
  end
end
