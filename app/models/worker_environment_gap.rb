# What a failed install showed a worker to be missing: a system library or
# header a native extension links against, or an executable the prepare
# commands call. The change is fine -- the same prepare passes on a correctly
# provisioned worker -- so the gap belongs to the worker, not to the Job.
#
# This is the reactive half of one placement model. The proactive half is
# the worker's environment smoke report (WorkerEnvironmentSmoke), which names
# failed checks. A gap is expressed the same way: as a failed check name
# (`check_name`), mapped onto the smoke check that covers the same thing when
# there is one (mysql2 failing to link zstd is the `mysql_client` check, a
# missing `gh` is the `gh` check). RunQueueResolver#environment_check_failures
# reads both through one code path, so a probe-detected and a failure-detected
# gap keep a worker off work identically and hold under the same reason.
#
# A gap applies to the repository whose install found it. It stops counting
# when it expires, when the worker restarted after it was detected (a
# reprovisioned worker deserves a fresh look), when that repository's prepare
# later succeeds on the worker, or when the worker's own smoke report passes
# the same check after the gap was found.
class WorkerEnvironmentGap < ApplicationRecord
  MISSING_KINDS = %w[library header executable].freeze
  TTL = 6.hours

  # Failures that a WorkerEnvironmentSmoke check already covers, so the two
  # name the same thing.
  MYSQL_CLIENT_NAMES = /\A(?:lib)?(?:mysqlclient|mariadb|zstd|ssl|crypto)\b|\Amysql\.h\z|\A(?:mysql|mariadb)_config\z/
  SMOKE_EXECUTABLES = {
    "git" => "git", "ruby" => "ruby", "bundle" => "bundler", "bundler" => "bundler",
    "node" => "node", "npm" => "npm", "npx" => "npm", "gh" => "gh",
    "cc" => "c_compiler", "gcc" => "c_compiler", "clang" => "c_compiler", "make" => "c_compiler"
  }.freeze

  validates :hostname, :missing_kind, :detected_at, :expires_at, presence: true
  validates :missing_kind, inclusion: { in: MISSING_KINDS }

  scope :uncleared, -> { where(cleared_at: nil) }
  scope :unexpired, ->(now = Time.current) { where("expires_at > ?", now) }

  class << self
    def record!(hostname:, missing_kind:, repository_id:, missing_name: nil, worker_storage_key: nil,
                run_id: nil, evidence: {}, now: Time.current)
      return nil if hostname.blank?

      existing = uncleared.unexpired(now).find_by(hostname: hostname, repository_id: repository_id,
                                                  missing_kind: missing_kind.to_s, missing_name: missing_name)
      if existing
        existing.update!(expires_at: now + TTL, run_id: run_id || existing.run_id, evidence: evidence.presence || existing.evidence)
        return existing
      end

      create!(
        hostname: hostname, worker_storage_key: worker_storage_key, repository_id: repository_id,
        missing_kind: missing_kind.to_s, missing_name: missing_name, run_id: run_id,
        evidence: evidence.presence, detected_at: now, expires_at: now + TTL
      )
    end

    # check name => reason for every gap that keeps `hostname` off this
    # repository's work, in the vocabulary of WorkerEnvironmentSmoke checks.
    #
    # A gap found while preparing one grader target (`xcodegen` missing for
    # an iOS target) says nothing about the rest of the repository: it only
    # holds work that runs that same target, named in `prepare_targets`.
    # Counting it everywhere once kept a worker off every step of the
    # repository, including landing trains that never run the target.
    def failed_checks(hostname:, repository_id:, smoke_report: nil, prepare_targets: [], now: Time.current)
      return {} if hostname.blank? || repository_id.blank?

      gaps = uncleared.unexpired(now).where(hostname: hostname, repository_id: repository_id).to_a
      return {} if gaps.empty?

      restarted_at = InstanceVersion.where(role: "worker", hostname: hostname).maximum(:started_at)
      gaps.each_with_object({}) do |gap, failed|
        next if restarted_at && restarted_at > gap.detected_at
        next if gap.passed_since?(smoke_report)
        next unless gap.applies_to_prepare_targets?(prepare_targets)

        failed[gap.check_name] ||= gap.reason
      end
    end

    # Clears what a success proves. A repository's own prepare installing
    # says nothing about a grader target's tool (it never ran `xcodegen`), so
    # it clears only untagged gaps; a grader that ran a prepare target clears
    # the gaps tagged with that target. Clearing everything on any prepare
    # once put an iOS target back on a worker still missing its tool.
    def clear!(hostname:, repository_id:, prepare_targets: nil, now: Time.current)
      return 0 if hostname.blank?

      labels = Array(prepare_targets).map(&:to_s)
      ids = uncleared.where(hostname: hostname, repository_id: repository_id).select(:id, :evidence).select do |gap|
        prepare_targets.nil? ? gap.prepare_target.nil? : labels.include?(gap.prepare_target)
      end.map(&:id)
      return 0 if ids.empty?

      where(id: ids).update_all(cleared_at: now, updated_at: now)
    end

    # The failure path: a Run whose step declared `worker_environment_missing`
    # names the host it failed on through its processes.
    #
    # Prepare can also stop before running anything because the worker's own
    # smoke report already failed checks the plan needs (`failed_checks`);
    # those are recorded under the smoke check's own name.
    def record_from_run!(run, problem_evidence:)
      evidence = problem_evidence.to_h.stringify_keys
      hostname = failure_hostname(run)
      return nil if hostname.blank? || run.job&.repository_id.blank?

      common = {
        hostname: hostname,
        worker_storage_key: run.distributed_parallel_run? ? nil : run.workflow&.worker_storage_key,
        repository_id: run.job.repository_id,
        run_id: run.id
      }
      kept = evidence.slice("command", "exit_status", "error_line", "failed_package", "prepare_target")
      if (checks = Array(evidence["failed_checks"]).map(&:to_s).compact_blank).any?
        return checks.map do |check|
          record!(**common, missing_kind: "executable", missing_name: check, evidence: kept.merge("check_name" => check))
        end.last
      end

      record!(
        **common,
        missing_kind: evidence["missing_kind"].presence_in(MISSING_KINDS) || "library",
        missing_name: evidence["missing_name"],
        evidence: kept
      )
    end

    def failure_hostname(run)
      run.spawned_processes.where.not(hostname: [ nil, "" ]).order(:id).last&.hostname.presence ||
        (run.workflow&.worker_hostname.presence unless run.distributed_parallel_run?)
    end
  end

  def prepare_target
    evidence.to_h["prepare_target"].presence
  end

  def applies_to_prepare_targets?(labels)
    prepare_target.nil? || Array(labels).map(&:to_s).include?(prepare_target)
  end

  def check_name
    declared = evidence.to_h["check_name"].presence
    return declared if declared

    name = missing_name.to_s
    package = evidence.to_h["failed_package"].to_s
    return "mysql_client" if package.start_with?("mysql2") || name.match?(MYSQL_CLIENT_NAMES) && missing_kind != "executable"
    return "mysql_client" if missing_kind == "executable" && name.match?(/\A(?:mysql|mariadb)_config\z/)
    return SMOKE_EXECUTABLES.fetch(File.basename(name)) if missing_kind == "executable" && SMOKE_EXECUTABLES.key?(File.basename(name))

    "missing_#{missing_kind}:#{name.presence || 'unknown'}"
  end

  def reason
    detail = evidence.to_h["error_line"].presence || [ missing_kind, missing_name ].compact.join(" ")
    "install failed on this worker (Run #{run_id || '?'}): #{detail}".truncate(300)
  end

  # The worker's smoke report checked this same thing, after the gap was
  # found, and it passed: whatever was missing has been provisioned.
  def passed_since?(report)
    return false unless report.is_a?(Hash)

    observed = Time.zone.parse(report["observed_at"].to_s) rescue nil
    return false unless observed && observed > detected_at

    report.dig("checks", check_name, "status") == WorkerEnvironmentSmoke::PASSED
  end
end
