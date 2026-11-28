module Coworkers
  class SensitiveChangeClassifier
    Result = Data.define(:reasons) { def sensitive? = reasons.any? }
    PATH_RULES = {
      "database migration or schema" => %r{\A(?:db/migrate/|db/schema\.rb\z)},
      "permission or security code" => %r{(?:\A|/)(?:permissions?|security|authorization|polic(?:y|ies))(?:/|_|\.|\z)}i,
      "default-setting change" => %r{(?:\A|/)(?:app_setting_registry|defaults?)(?:/|_|\.|\z)}i,
      "grader configuration" => %r{(?:\A|/)\.syrus\.yml\z}
    }.freeze
    API_VERSION = /^\+.*(?:["']v["']|\bv\b)\s*(?::|=>|=)\s*["']?\d+/i

    def self.call(job)
      files = job.diff_review_versions.all_changes.latest_first.first&.files_snapshot.to_a
      reasons = files.flat_map do |file|
        path = file["path"].to_s
        matches = PATH_RULES.filter_map { |reason, pattern| reason if path.match?(pattern) }
        if path.match?(%r{(?:\A|/)api(?:/|_|\.)}i) && file["patch"].to_s.lines.any? { |line| line.match?(API_VERSION) }
          matches << "top-level JSON API version"
        end
        matches
      end
      Result.new(reasons.uniq)
    end
  end
end
