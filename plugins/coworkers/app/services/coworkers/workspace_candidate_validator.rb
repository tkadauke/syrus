require "json"
require "yaml"

class Coworkers::WorkspaceCandidateValidator
  ValidationError = Class.new(StandardError)
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
    paths = @git.run("diff", "--name-only", "--diff-filter=U", chdir: @path.to_s).lines.map(&:strip).reject(&:blank?)
    raise ValidationError, "unmerged index entries remain in #{paths.join(', ')}" if paths.any?
  end

  def reject_diff_errors!(base_sha)
    result = @git.capture("diff", "--check", base_sha, "HEAD", chdir: @path.to_s)
    return if result.success?

    raise ValidationError, "git diff --check rejected the workspace: #{result.stdout}#{result.stderr}".strip
  end

  def changed_paths(base_sha)
    @git.run("diff", "--name-only", "--diff-filter=ACMR", base_sha, "HEAD", chdir: @path.to_s)
      .lines.map(&:strip).reject(&:blank?)
  end

  def validate_file!(relative)
    candidate = Syrus::PathJail.resolve!(@path, relative)
    return if candidate.symlink? || !candidate.file?

    content = File.binread(candidate)
    return if content.include?("\0")
    raise ValidationError, "conflict markers remain in #{relative}" if content.match?(CONFLICT_MARKER)

    case candidate.extname.downcase
    when ".json"
      JSON.parse(content)
    when ".yml", ".yaml"
      Psych.parse_stream(content)
    end
  rescue JSON::ParserError, Psych::Exception => error
    raise ValidationError, "#{relative} is invalid: #{error.message}"
  rescue Syrus::PathJail::PathEscape, Errno::EACCES, Errno::ELOOP => error
    raise ValidationError, "#{relative} cannot be validated safely: #{error.message}"
  end
end
