class JobAttachmentContext
  ATTACHMENTS_DIR = Pathname("tmp/attachments").freeze

  Entry = Data.define(:name, :type, :path, :url)

  def initialize(job:, workspace_path:)
    @job = job
    @workspace_path = Pathname(workspace_path)
  end

  def materialize!
    attachments.map.with_object([]) do |attachment, entries|
      if attachment.uploaded_file?
        entries << materialize_file(attachment)
      elsif attachment.google_doc_link?
        entries << Entry.new(
          name: "Google Doc",
          type: "google_doc_link",
          path: nil,
          url: attachment.google_doc_url
        )
      end
    end
  end

  def apply_to(prompt)
    entries = materialize!
    return prompt if entries.empty?

    [ prompt, prompt_section(entries) ].join("\n\n")
  end

  private

  attr_reader :job, :workspace_path

  def attachments
    job.job_attachments.includes(file_attachment: :blob).order(:created_at, :id)
  end

  def materialize_file(attachment)
    dir = workspace_path.join(ATTACHMENTS_DIR)
    FileUtils.mkdir_p(dir)

    filename = unique_filename(dir, attachment.file.filename.sanitized)
    path = dir.join(filename)
    File.binwrite(path, attachment.file.download)

    Entry.new(
      name: attachment.file.filename.to_s,
      type: attachment.file.blob.content_type.to_s,
      path: ATTACHMENTS_DIR.join(filename).to_s,
      url: nil
    )
  end

  def unique_filename(dir, filename)
    basename = File.basename(filename, ".*")
    extension = File.extname(filename)
    candidate = filename
    counter = 2

    while File.exist?(dir.join(candidate))
      candidate = "#{basename}-#{counter}#{extension}"
      counter += 1
    end

    candidate
  end

  def prompt_section(entries)
    lines = entries.map do |entry|
      if entry.url
        "- #{entry.name} (#{entry.type}): #{entry.url}"
      else
        "- #{entry.name} (#{entry.type}): #{entry.path}"
      end
    end

    <<~PROMPT.strip
      # Job Attachments

      The operator attached supporting context for this Job. Uploaded files have been downloaded into the workspace; inspect them directly when relevant.

      #{lines.join("\n")}
    PROMPT
  end
end
