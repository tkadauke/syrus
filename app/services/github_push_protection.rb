# Detects GitHub push-protection (GH013 secret scanning) rejections at the
# shared authenticated push boundary (GithubAuthenticatedGit) and turns them
# into a typed, *sanitized* error.
#
# GitHub is the authoritative detector: we never scan content ourselves. We
# only parse the structured part of the remote's message -- secret type, commit
# SHA, and path/line -- and drop everything else. Secret material and the
# "allow this secret" bypass URL are never copied into the error, the logs, or
# the ledger.
#
# Recovery is owned by the calling workflow (see PushProtection::Recovery);
# this file only classifies.
module GithubPushProtection
  SECTION_PATTERN = /\A\s*[—–-]{2,}\s*(?<type>.+?)\s*[—–-]{2,}.*\z/
  COMMIT_PATTERN = /\bcommit:\s*(?<sha>\h{7,40})\b/i
  PATH_PATTERN = /\bpath:\s*(?<path>\S+)/i
  DETECTION_PATTERN = /GH013|GITHUB PUSH PROTECTION|Push cannot contain secrets/i
  MAX_FINDINGS = 50
  MAX_FIELD_LENGTH = 200

  Finding = Data.define(:secret_type, :commit_sha, :path, :line) do
    def to_h
      { "secret_type" => secret_type, "commit_sha" => commit_sha, "path" => path, "line" => line }
    end
  end

  # Subclasses GitError so every existing `rescue GitRunner::GitError` keeps
  # working; its #output and #message contain only the sanitized summary.
  class Rejected < GitRunner::GitError
    attr_reader :findings, :ref

    def initialize(command, exit_status, findings:, ref:)
      @findings = findings.freeze
      @ref = ref
      super(command, exit_status, GithubPushProtection.summary(findings, ref))
    end

    def commit_shas = findings.map(&:commit_sha).compact.uniq
    def finding_paths = findings.map(&:path).compact.uniq
  end

  module_function

  def detect?(text)
    text.to_s.match?(DETECTION_PATTERN) && text.to_s.match?(/secret|push protection/i)
  end

  # Returns the original error unchanged unless it is a push-protection
  # rejection, in which case a Rejected carrying sanitized findings.
  def reclassify(error)
    return error if error.is_a?(Rejected)

    text = error.output.to_s
    return error unless error.command.to_a.include?("push") && detect?(text)

    Rejected.new(error.command, error.exit_status, findings: parse(text), ref: target_ref(error.command))
  end

  def parse(text)
    findings = []
    type = nil
    commit = nil
    text.to_s.each_line do |raw|
      line = raw.sub(/\Aremote:\s?/, "").rstrip
      if (m = line.match(SECTION_PATTERN)) && !line.match?(%r{://})
        type = clean(m[:type])
        commit = nil
      elsif (m = line.match(COMMIT_PATTERN))
        commit = m[:sha].downcase
      elsif (m = line.match(PATH_PATTERN))
        path, line_no = split_path(m[:path])
        findings << Finding.new(secret_type: type, commit_sha: commit, path: path, line: line_no)
      end
      break if findings.size >= MAX_FINDINGS
    end
    findings
  end

  def split_path(value)
    return [ nil, nil ] if value.match?(%r{://})

    path, line = value.match(/\A(.*?)(?::(\d+))?\z/).captures
    [ clean(path), line&.to_i ]
  end

  def clean(value)
    value.to_s.gsub(/[^[:print:]]/, "").strip.first(MAX_FIELD_LENGTH).presence
  end

  def target_ref(command)
    spec = command.to_a.reverse.find { |arg| arg.to_s.include?(":") && !arg.to_s.match?(%r{://}) }
    spec.to_s.split(":", 2).last.presence
  end

  def summary(findings, ref)
    lines = [ "GitHub push protection (GH013) rejected the push#{" to #{ref}" if ref}" ]
    findings.each do |f|
      lines << "- #{f.secret_type || 'secret'} in #{f.path || 'unknown path'}#{":#{f.line}" if f.line}" \
               "#{" (commit #{f.commit_sha.first(12)})" if f.commit_sha}"
    end
    lines.join("\n")
  end
end
