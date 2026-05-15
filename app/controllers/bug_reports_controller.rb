require "stringio"

class BugReportsController < ApplicationController
  TARGET_OWNER = "tkadauke".freeze
  TARGET_NAME = "syrus".freeze

  def create
    repository = Current.user.repositories.active.find_by(owner: TARGET_OWNER, name: TARGET_NAME)
    unless repository
      redirect_back fallback_location: root_path, alert: "Bug report repository #{TARGET_OWNER}/#{TARGET_NAME} is not configured."
      return
    end

    title = params[:title].to_s.strip.presence || "In-app bug report"
    description = params[:description].to_s.strip
    prompt_text = [ title, description ].reject(&:blank?).join("\n\n")
    screenshot = params[:screenshot]

    unless screenshot.present?
      redirect_back fallback_location: root_path, alert: "Screenshot is required."
      return
    end
    unless screenshot.content_type == "image/png"
      redirect_back fallback_location: root_path, alert: "Screenshot must be a PNG."
      return
    end

    job = nil
    ActiveRecord::Base.transaction do
      job = Current.user.jobs.create!(
        repository: repository,
        kind: "direct",
        issue_number: nil,
        issue_title: title,
        issue_body: prompt_text,
        agent_provider: repository.effective_agent_provider,
        priority: "medium"
      )

      Workflows::Initial.instantiate(job: job, agent_provider: job.agent_provider)
      attach_screenshot!(job, screenshot)
    end

    redirect_to job_path(job), notice: "Bug report queued."
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: root_path, alert: e.record.errors.full_messages.to_sentence
  end

  private

  def attach_screenshot!(job, upload)
    body = upload.read
    filename = upload.original_filename.presence || "bug-report-screenshot.png"
    content_type = upload.content_type.presence || "image/png"

    attachment = job.job_attachments.build(
      source_url: "bug-report://#{SecureRandom.uuid}",
      filename: filename,
      content_type: content_type,
      byte_size: body.bytesize
    )
    attachment.file.attach(
      io: StringIO.new(body),
      filename: filename,
      content_type: content_type,
      identify: false
    )
    attachment.save!
  end
end
