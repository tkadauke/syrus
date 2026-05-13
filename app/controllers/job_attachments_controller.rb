class JobAttachmentsController < ApplicationController
  before_action :load_job

  def create
    created = []
    errors = []

    uploaded_files.each do |file|
      attachment = @job.job_attachments.build(attachment_type: "uploaded_file")
      attachment.file.attach(file)
      if attachment.save
        created << attachment
      else
        errors.concat(attachment.errors.full_messages)
      end
    end

    if google_doc_url.present?
      attachment = @job.job_attachments.build(
        attachment_type: "google_doc_link",
        google_doc_url: google_doc_url
      )
      if attachment.save
        created << attachment
      else
        errors.concat(attachment.errors.full_messages)
      end
    end

    if created.any? && errors.empty?
      redirect_to job_path(@job, tab: "attachments"), notice: "Attachment added."
    elsif created.any?
      redirect_to job_path(@job, tab: "attachments"),
                  alert: "Some attachments could not be added: #{errors.to_sentence}"
    else
      redirect_to job_path(@job, tab: "attachments"),
                  alert: errors.presence&.to_sentence || "Choose a file or enter a Google Doc URL."
    end
  end

  def destroy
    attachment = @job.job_attachments.find(params[:id])
    attachment.destroy!
    redirect_to job_path(@job, tab: "attachments"), notice: "Attachment removed."
  end

  private

  def load_job
    @job = Current.user.jobs.find(params[:job_id])
  end

  def uploaded_files
    Array(params.dig(:job_attachment, :files)).compact_blank
  end

  def google_doc_url
    params.dig(:job_attachment, :google_doc_url).to_s.strip
  end
end
