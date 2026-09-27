module OperatorBriefing
  class GenerateRunStep < ::Steps::Base
    RECENT_JOB_LIMIT = 5

    def call
      briefing = Briefing.find_by!(job: job)
      revision = create_revision!(briefing)
      log("created operator briefing revision #{revision.revision_number} for #{repository.slug}")
    end

    private

    def create_revision!(briefing)
      briefing.revisions.create!(
        revision_number: briefing.revisions.maximum(:revision_number).to_i + 1,
        generated_at: Time.current,
        generation_run: run,
        content_blocks: content_blocks(briefing)
      )
    end

    def content_blocks(briefing)
      [
        narrative_block(briefing),
        *recent_job_cards(briefing)
      ]
    end

    def narrative_block(briefing)
      jobs_count = recent_jobs_scope(briefing).count
      text = if jobs_count.zero?
        "No notable activity was found for #{repository.slug} in this briefing window."
      else
        "Briefing window for #{repository.slug}: #{jobs_count} recent Jobs."
      end

      { "kind" => "narrative", "payload" => { "text" => text } }
    end

    def recent_job_cards(briefing)
      recent_jobs_scope(briefing).limit(RECENT_JOB_LIMIT).map do |recent_job|
        link_card(
          entity_type: "job",
          entity_id: recent_job.id,
          title: recent_job.issue_title.presence || recent_job.slug,
          path: "/jobs/#{recent_job.id}",
          description: "#{recent_job.kind.humanize} / #{recent_job.state}"
        )
      end
    end

    def link_card(entity_type:, entity_id:, title:, path:, description:)
      {
        "kind" => "link_card",
        "payload" => {
          "entity_type" => entity_type,
          "entity_id" => entity_id,
          "title" => title,
          "path" => path,
          "description" => description
        }
      }
    end

    def recent_jobs_scope(briefing)
      repository.jobs
        .where.not(kind: ActivityGate::EXCLUDED_JOB_KINDS)
        .where("jobs.created_at >= :start_at AND jobs.created_at <= :end_at", start_at: briefing.window_start, end_at: briefing.window_end)
        .order(created_at: :desc, id: :desc)
    end
  end
end
