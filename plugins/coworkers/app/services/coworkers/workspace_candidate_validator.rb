require "json"
require "yaml"

class Coworkers::WorkspaceCandidateValidator
  class ValidationError < StandardError
    attr_reader :relative_path

    def initialize(message, relative_path: nil)
      @relative_path = relative_path
      super(message)
    end
  end
  CONFLICT_MARKER = /^(?:<<<<<<<|=======|>>>>>>>)(?: |$)/

  def initialize(path, git: GitRunner.new)
    @path = Pathname(path)
    @git = git
  end

  def validate!(base_sha:)
    reject_unmerged!
    reject_diff_errors!(base_sha)
    changed_paths(base_sha).each { |relative| validate_file!(relative) }
    true
  end

  private

  def reject_unmerged!
    paths = nul_paths(@git.run("diff", "--name-only", "-z", "--diff-filter=U", chdir: @path.to_s))
    raise ValidationError, "unmerged index entries remain in #{paths.join(', ')}" if paths.any?
  end

  def reject_diff_errors!(base_sha)
    result = @git.capture("diff", "--check", base_sha, "HEAD", chdir: @path.to_s)
    return if result.success?

    raise ValidationError, "git diff --check rejected the workspace: #{result.stdout}#{result.stderr}".strip
  end

  def changed_paths(base_sha)
    nul_paths(@git.run("diff", "--name-only", "-z", "--diff-filter=ACMR", base_sha, "HEAD", chdir: @path.to_s))
  end

  def nul_paths(output) = output.split("\0")

  def validate_file!(relative)
    candidate = Syrus::PathJail.resolve!(@path, relative)
    return if candidate.symlink? || !candidate.file?

    content = File.binread(candidate)
    return if content.include?("\0")
    raise ValidationError.new("conflict markers remain in #{relative}", relative_path: relative) if content.match?(CONFLICT_MARKER)

    case candidate.extname.downcase
    when ".json"
      JSON.parse(content)
    when ".yml", ".yaml"
      Psych.parse_stream(content)
    end
  rescue JSON::ParserError, Psych::Exception => error
    raise ValidationError.new("#{relative} is invalid: #{error.message}", relative_path: relative)
  rescue Syrus::PathJail::PathEscape, Errno::EACCES, Errno::ELOOP => error
    raise ValidationError.new("#{relative} cannot be validated safely: #{error.message}", relative_path: relative)
  end
end
