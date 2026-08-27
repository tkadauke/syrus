class JobAttachmentContext
  ATTACHMENTS_DIR = Pathname("tmp/attachments").freeze
  PREVIEW_PANEL_MOCKUP_REF_PREFIX = "preview_panel_version:"

  PREVIEW_PANEL_MOCKUP_NOTE = <<~TEXT.strip
    Some of the files above are static HTML/CSS/JS source from a preview
    panel mockup a planning chat agent built. Treat them as reference
    material describing the intended look and behavior -- adapt the ideas to
    this repo's own conventions (framework, component structure, styling
    system) rather than copying the markup or files verbatim.
  TEXT

  Entry = Data.define(:name, :type, :path, :url, :reference_only)

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
          url: attachment.google_doc_url,
          reference_only: false
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
      url: nil,
      reference_only: preview_panel_mockup?(attachment)
    )
  end

  def preview_panel_mockup?(attachment)
    attachment.source_url.to_s.start_with?(PREVIEW_PANEL_MOCKUP_REF_PREFIX)
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

    mockup_note = entries.any?(&:reference_only) ? "\n\n#{PREVIEW_PANEL_MOCKUP_NOTE}" : ""

    <<~PROMPT.strip
      # Job Attachments

      The operator attached supporting context for this Job. Uploaded files have been downloaded into the workspace; inspect them directly when relevant.

      #{lines.join("\n")}#{mockup_note}
    PROMPT
  end
end
