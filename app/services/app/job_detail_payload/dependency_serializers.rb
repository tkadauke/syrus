module App
  class JobDetailPayload
    module DependencySerializers
      extend ActiveSupport::Concern

      # Dependency serialization extracted from JobDetailPayload: the depends-on /
      # dependent edges, the per-dependency target job JSON, and the operator
      # dependency-picker option list. Mixed back in via ActiveSupport::Concern.

      def dependency_json(dependency)
        job_target = dependency.depends_on_job
        epic_target = dependency.depends_on_epic
        {
          id: dependency.id,
          source: dependency.source,
          manual: dependency.manual?,
          pending: dependency.pending?,
          succeeded: dependency.dependency_succeeded?,
          unresolved_slug: dependency.unresolved_slug,
          created_by_user_id: dependency.created_by_user_id,
          depends_on_job: job_target && dependency_job_json(job_target),
          depends_on_epic: epic_target && dependency_epic_json(epic_target)
        }
      end

      def dependent_json(dependency)
        {
          id: dependency.id,
          source: dependency.source,
          job: dependency_job_json(dependency.job)
        }
      end

      def dependency_job_json(job)
        {
          id: job.id,
          kind: job.kind,
          state: job.state,
          summary_state: summary_state(job),
          repository_slug: job.repository.slug,
          issue_number: job.issue_number,
          issue_title: job.issue_title,
          branch_name: job.branch_name,
          pr_number: job.pr_number,
          job_path: job_path(job)
        }
      end

      def dependency_epic_json(epic)
        {
          id: epic.id,
          number: epic.number,
          slug: epic.slug,
          title: epic.title,
          state: epic.state,
          display_number: epic.slug,
          repository_slug: epic.repository.slug,
          epic_path: epic_path(epic)
        }
      end

      def dependency_target_options
        jobs = @user.jobs
                    .includes(:repository)
                    .where.not(id: @job.id)
                    .order(created_at: :desc, id: :desc)

        seen_issues = {}
        current_issue_key = @job.issue? && @job.issue_number.present? ? [ @job.repository_id, @job.issue_number ] : nil
        jobs.each_with_object([]) do |job, options|
          if job.issue? && job.issue_number.present?
            issue_key = [ job.repository_id, job.issue_number ]
            next if issue_key == current_issue_key
            next if seen_issues[issue_key]

            seen_issues[issue_key] = true
            options << { label: dependency_target_label(job), value: "issue:#{job.repository_id}:#{job.issue_number}" }
          else
            options << { label: dependency_target_label(job), value: "job:#{job.id}" }
          end
        end
      end

      def dependency_target_label(job)
        if job.issue? && job.issue_number.present?
          title = job.issue_title.to_s.strip
          title = " - #{title}" if title.present?
          "#{job.repository.slug} ##{job.issue_number}#{title} (#{job.slug})"
        else
          title = job.issue_title.to_s.strip.presence || job.kind.titleize
          "#{job.repository.slug} #{job.slug} - #{title}"
        end
      end

      def epic_dependency_target_options
        @user.epics
             .where(repository: @job.repository)
             .order(created_at: :desc, id: :desc)
             .map { |epic| { label: "#{epic.slug} — #{epic.title}", value: epic.id } }
      end
    end
  end
end
