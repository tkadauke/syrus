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
          unresolved_ref_kind: dependency.pending_reference_kind,
          unresolved_ref_state: dependency.pending_reference_state,
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
        rows = @user.jobs
                    .joins(:repository)
                    .where.not(id: @job.id)
                    .order("jobs.created_at DESC", "jobs.id DESC")
                    .pluck(
                      "jobs.id",
                      "jobs.kind",
                      "jobs.repository_id",
                      "jobs.issue_number",
                      "jobs.issue_title",
                      "repositories.owner",
                      "repositories.name"
                    )

        seen_issues = {}
        current_issue_key = @job.issue? && @job.issue_number.present? ? [ @job.repository_id, @job.issue_number ] : nil
        rows.each_with_object([]) do |(id, kind, repository_id, issue_number, issue_title, owner, name), options|
          repository_slug = "#{owner}/#{name}"

          if kind == "issue" && issue_number.present?
            issue_key = [ repository_id, issue_number ]
            next if issue_key == current_issue_key
            next if seen_issues[issue_key]

            seen_issues[issue_key] = true
            options << {
              label: dependency_target_label_from_row(
                id: id,
                kind: kind,
                repository_slug: repository_slug,
                issue_number: issue_number,
                issue_title: issue_title
              ),
              value: "issue:#{repository_id}:#{issue_number}"
            }
          else
            options << {
              label: dependency_target_label_from_row(
                id: id,
                kind: kind,
                repository_slug: repository_slug,
                issue_number: issue_number,
                issue_title: issue_title
              ),
              value: "job:#{id}"
            }
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

      def dependency_target_label_from_row(id:, kind:, repository_slug:, issue_number:, issue_title:)
        if kind == "issue" && issue_number.present?
          title = issue_title.to_s.strip
          title = " - #{title}" if title.present?
          "#{repository_slug} ##{issue_number}#{title} (#{App::Presentation.job_slug(id)})"
        else
          title = issue_title.to_s.strip.presence || kind.to_s.titleize
          "#{repository_slug} #{App::Presentation.job_slug(id)} - #{title}"
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
