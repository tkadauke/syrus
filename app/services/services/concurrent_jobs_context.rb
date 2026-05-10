module Services
  class ConcurrentJobsContext
    Entry = Struct.new(:job_id, :issue_title, :files, :fallback_text, :conflicting_files, keyword_init: true) do
      def conflict?
        conflicting_files.present?
      end
    end

    PATH_PATTERN = %r{\b(?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+\.[A-Za-z0-9]+\b}.freeze

    def initialize(job:, github_client: nil, git: nil)
      @job = job
      @repository = job.repository
      @github_client = github_client
      @git = git || GitRunner.new
    end

    def entries
      @entries ||= other_in_flight_jobs.map { |other| build_entry(other) }
    end

    def to_prompt_section
      return nil if entries.empty?

      lines = [ "Other Syrus Jobs running on this repo right now:" ]
      entries.each do |entry|
        files = entry.files.presence || [ "unknown files" ]
        line = "- Job ##{entry.job_id} (issue: #{entry.issue_title.inspect}): touching #{files.join(', ')}"
        if entry.conflict?
          line << " (conflicts on #{entry.conflicting_files.join(', ')})"
        elsif entry.fallback_text.present? && entry.files.blank?
          line << " (no branch diff yet; issue context: #{entry.fallback_text})"
        end
        lines << line
      end
      lines << "Avoid stomping their changes; coordinate via PR comments if work overlaps."
      lines.join("\n")
    end

    private

    attr_reader :job, :repository, :git

    def github_client
      @github_client ||= GithubClient.for(job.user)
    end

    def other_in_flight_jobs
      Job.open_threads
         .where(repository: repository)
         .where.not(id: job.id)
         .joins(:workflows)
         .merge(Workflow.active)
         .distinct
         .order(:id)
    end

    def build_entry(other)
      files = changed_files_for(other)
      fallback_text = nil
      if files.blank?
        fallback_files = paths_from_issue_text(other)
        files = fallback_files
        fallback_text = issue_excerpt(other) if fallback_files.blank?
      end

      Entry.new(
        job_id: other.id,
        issue_title: issue_title(other),
        files: files,
        fallback_text: fallback_text,
        conflicting_files: files & current_job_files
      )
    end

    def changed_files_for(other)
      local_changed_files(other).presence || remote_changed_files(other).presence || []
    end

    def local_changed_files(other)
      workflow = other.workflows.active.last || other.latest_workflow
      return [] unless workflow

      path = WorkflowWorkspace.path_for(workflow)
      return [] unless path.exist?

      diff_files = git.run("diff", "--name-only", "#{repository.default_branch}...HEAD", chdir: path.to_s).lines
      status_files = git.run("status", "--porcelain", chdir: path.to_s).lines.map { |line| path_from_status(line) }
      (diff_files.map(&:strip) + status_files).compact_blank.uniq.sort
    rescue StandardError => e
      Rails.logger.warn("[ConcurrentJobsContext] local diff failed for job ##{other.id}: #{e.class}: #{e.message}")
      []
    end

    def remote_changed_files(other)
      branch = other.branch_name.presence || WorkflowWorkspace.new(other.latest_workflow).branch_name
      github_client.changed_files_between(repository.slug, repository.default_branch, branch)
    rescue StandardError => e
      Rails.logger.warn("[ConcurrentJobsContext] remote diff failed for job ##{other.id}: #{e.class}: #{e.message}")
      []
    end

    def current_job_files
      @current_job_files ||= changed_files_for(job)
    end

    def path_from_status(line)
      raw = line.to_s[3..]&.strip
      return nil if raw.blank?
      raw = raw.split(" -> ", 2).last if raw.include?(" -> ")
      raw.delete_prefix('"').delete_suffix('"')
    end

    def paths_from_issue_text(other)
      [ other.issue_title, other.issue_body ].join("\n").scan(PATH_PATTERN).uniq.sort
    end

    def issue_title(other)
      other.issue_title.presence || "Issue ##{other.issue_number || other.id}"
    end

    def issue_excerpt(other)
      text = [ other.issue_title, other.issue_body ].join(" ").squish
      return nil if text.blank?
      text.truncate(160)
    end
  end
end
