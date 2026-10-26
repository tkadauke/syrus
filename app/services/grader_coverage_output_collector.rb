require "pathname"

# Persists only the coverage files a grader explicitly declared. Immutable
# grader checkouts are worker-local and disposable, so the Run is the durable
# boundary between grader execution and the later coverage_analyze Step.
class GraderCoverageOutputCollector
  Result = Data.define(:artifact, :format, :status, :reason)

  def self.call(run:, workspace_path:, outputs:, grader_name:, project_path:, source_snapshot_id:, log:)
    new(run:, workspace_path:, outputs:, grader_name:, project_path:, source_snapshot_id:, log:).call
  end

  def initialize(run:, workspace_path:, outputs:, grader_name:, project_path:, source_snapshot_id:, log:)
    @run = run
    @workspace_path = Pathname.new(workspace_path).expand_path
    @outputs = Array(outputs)
    @grader_name = grader_name
    @project_path = project_path.to_s
    @source_snapshot_id = source_snapshot_id
    @log = log
  end

  def call
    # A Run can be retried in place after a worker interruption. Replace its
    # collection rather than retaining an attachment from the aborted attempt.
    @run.coverage_outputs.purge if @run.coverage_outputs.attached?
    @outputs.map { |output| collect(output.to_h.stringify_keys) }
  end

  private

  def collect(output)
    artifact = output["artifact"].to_s
    format = output["format"].to_s
    relative_path = repository_relative_path(artifact)
    return rejected(artifact:, format:, reason: "unsafe path") if relative_path.blank?

    candidate = @workspace_path.join(relative_path)
    return absent(artifact: relative_path, format:, reason: "file was not produced") unless candidate.exist?

    path = safe_regular_file(relative_path)
    unless path
      return rejected(artifact: relative_path.presence || artifact, format:, reason: "missing or unsafe regular file")
    end

    validator = CoverageOutputValidation::Base.for(format)
    return rejected(artifact: relative_path, format:, reason: "unsupported coverage format") unless validator

    validation = validator.validate(path)
    return rejected(artifact: relative_path, format:, reason: validation.reason) unless validation.valid?

    File.open(path, "rb") do |io|
      @run.coverage_outputs.attach(
        io:,
        filename: "grader-#{@run.id}-#{File.basename(relative_path)}",
        content_type: "text/plain",
        identify: false,
        metadata: {
          "artifact" => relative_path,
          "format" => format,
          "grader_name" => @grader_name,
          "project_path" => @project_path,
          "source_snapshot_id" => @source_snapshot_id,
          "workspace_path" => @workspace_path.to_s
        }.compact
      )
    end
    @log.call("[grader:#{@grader_name}] retained coverage output #{relative_path} (#{format})")
    Result.new(artifact: relative_path, format:, status: "retained", reason: nil)
  rescue StandardError => e
    @log.call("[grader:#{@grader_name}] coverage output collection failed for #{artifact.inspect}: #{e.class}: #{e.message}")
    Result.new(artifact:, format:, status: "absent", reason: e.message)
  end

  def rejected(artifact:, format:, reason:)
    @log.call("[grader:#{@grader_name}] coverage output rejected: #{artifact.inspect} (#{reason})")
    Result.new(artifact:, format:, status: "rejected", reason:)
  end

  def absent(artifact:, format:, reason:)
    @log.call("[grader:#{@grader_name}] coverage output absent: #{artifact.inspect} (#{reason})")
    Result.new(artifact:, format:, status: "absent", reason:)
  end

  def repository_relative_path(artifact)
    candidate = Pathname.new(artifact)
    return "" if artifact.blank? || candidate.absolute?

    relative = Pathname.new(@project_path).join(candidate).cleanpath
    value = relative.to_s
    return "" if value == "." || value == ".." || value.start_with?("../")

    value
  end

  def safe_regular_file(relative_path)
    return if relative_path.blank?

    candidate = @workspace_path.join(relative_path)
    return unless candidate.file?
    return if candidate.symlink?

    real = candidate.realpath
    return unless real.to_s.start_with?("#{@workspace_path.realpath}/")

    real
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end
end
