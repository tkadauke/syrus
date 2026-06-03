module Api
  module V1
    module App
      class ProfilesController < BaseController
        RECENT_LIMIT = 8

        def index
          users = User.order(Arel.sql("LOWER(email_address) ASC"), :id)
                      .includes(:repositories, :epics, :jobs)

          render json: {
            team_user_count: User.count,
            profiles: users.map { |user| directory_user_json(user) }
          }
        end

        def show
          user = User.find(params[:id])

          render json: {
            team_user_count: User.count,
            profile: profile_json(user)
          }
        end

        private

        def directory_user_json(user)
          {
            id: user.id,
            display_name: user.team_display_name,
            first_name: user.first_name,
            last_name: user.last_name,
            github_handle: user.github_handle,
            avatar_url: user.avatar_url,
            bio_excerpt: user.profile_bio.to_s.truncate(160),
            counts: counts_json(user),
            profile_path: profile_path(user)
          }
        end

        def profile_json(user)
          {
            id: user.id,
            display_name: user.team_display_name,
            first_name: user.first_name,
            last_name: user.last_name,
            github_handle: user.github_handle,
            role_label: user.admin? ? "Admin" : "Operator",
            profile_bio: user.profile_bio,
            profile_location: user.profile_location,
            profile_company: user.profile_company,
            profile_website: user.profile_website,
            avatar_url: user.avatar_url,
            counts: counts_json(user),
            repositories: user.repositories.active.order(:owner, :name, :id).limit(RECENT_LIMIT).map { |repository| repository_json(repository) },
            epics: user.epics.includes(:repository).where.not(state: Epic::ARCHIVED_STATE).order(updated_at: :desc, id: :desc).limit(RECENT_LIMIT).map { |epic| epic_json(epic) },
            jobs: user.jobs.includes(:repository).order(updated_at: :desc, id: :desc).limit(RECENT_LIMIT).map { |job| job_json(job, show_owner: show_owner_labels_for?(user)) },
            recent_activity: recent_activity_json(user)
          }
        end

        def counts_json(user)
          {
            repositories: user.repositories.active.count,
            epics: user.epics.where.not(state: Epic::ARCHIVED_STATE).count,
            jobs: user.jobs.count,
            open_jobs: user.jobs.where.not(state: "closed").count
          }
        end

        def repository_json(repository)
          {
            id: repository.id,
            slug: repository.slug,
            path: repository_path(repository)
          }
        end

        def epic_json(epic)
          {
            id: epic.id,
            display_number: epic.display_number,
            title: epic.title,
            state: epic.state,
            repository: repository_json(epic.repository),
            updated_at: epic.updated_at&.iso8601,
            path: epic_path(epic)
          }
        end

        def job_json(job, show_owner:)
          {
            id: job.id,
            title: job.issue_title.presence || job.kind.humanize,
            state: job.state,
            kind: job.kind,
            repository: repository_json(job.repository),
            updated_at: job.updated_at&.iso8601,
            path: job_path(job),
            owner: show_owner ? owner_json(job.user) : nil
          }.compact
        end

        def recent_activity_json(user)
          activities = []
          user.jobs.includes(:repository).order(updated_at: :desc, id: :desc).limit(RECENT_LIMIT).each do |job|
            activities << {
              type: "job",
              title: job.issue_title.presence || job.kind.humanize,
              state: job.state,
              repository_slug: job.repository.slug,
              occurred_at: job.updated_at&.iso8601,
              path: job_path(job)
            }
          end
          user.epics.includes(:repository).where.not(state: Epic::ARCHIVED_STATE).order(updated_at: :desc, id: :desc).limit(RECENT_LIMIT).each do |epic|
            activities << {
              type: "epic",
              title: epic.title,
              state: epic.state,
              repository_slug: epic.repository.slug,
              occurred_at: epic.updated_at&.iso8601,
              path: epic_path(epic)
            }
          end

          activities.sort_by { |activity| activity.fetch(:occurred_at).to_s }.reverse.first(RECENT_LIMIT)
        end

        def owner_json(user)
          {
            id: user.id,
            display_name: user.display_name,
            profile_path: profile_path(user)
          }
        end

        def show_owner_labels_for?(profile_user)
          Current.user.id != profile_user.id && User.where.not(id: Current.user.id).exists?
        end
      end
    end
  end
end
