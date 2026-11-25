require "digest"

# Native macOS worker releases, published by every deploy.
#
# A deploy uploads the signed source artifact for the revision it is rolling
# out (store!), activates it once the cluster's migrations have run
# (activate!), and then waits until every live Mac worker reports that revision
# (status). Syrus serves the artifact itself, over the same HTTPS host and with
# the same scoped token the updater already uses, so Mac hosts need no other
# download source.
#
# An activated release rolls out immediately: the updater installs it and
# restarts the worker gracefully, the way a pod is replaced, rather than
# waiting for the host to drain first. The drain flow in MacosWorkerRollout
# remains for manual, one-host-at-a-time updates.
class MacosWorkerRelease
  ROLLOUT_IMMEDIATE = "immediate".freeze
  POLL_INTERVAL_SECONDS = 60
  GIT_SHA_PATTERN = /\A[0-9a-f]{7,40}\z/
  ARTIFACT_NAME_PATTERN = /\A[A-Za-z0-9._-]{1,200}\z/
  # Mac workers seen within this window but no longer heartbeating are
  # reported as offline, so a deploy can say which hosts it could not reach.
  OFFLINE_WINDOW = 7.days

  DigestMismatch = Class.new(StandardError)

  # True when two revisions name the same commit, whatever abbreviation
  # length each side used.
  def self.same_revision?(left, right)
    left = left.to_s
    right = right.to_s
    return false if left.length < 7 || right.length < 7

    left.start_with?(right) || right.start_with?(left)
  end

  # The URL Mac hosts reach Syrus at; the updater requires HTTPS.
  # SYRUS_APP_HOST is that public host, while behind the ingress a request's
  # own base URL may be an internal one.
  def self.public_base_url(fallback:)
    host = ENV["SYRUS_APP_HOST"].to_s.strip.chomp("/")
    return fallback if host.blank?
    return host if host.match?(%r{\Ahttps?://}i)

    "https://#{host}"
  end

  def self.desired_git_sha
    AppSetting.macos_worker_desired_release["git_sha"].presence
  end

  def self.macos_worker?(instance)
    Array(WorkerCapabilities.normalize(instance.capabilities)["os"]).map(&:to_s).include?("macos")
  end

  def self.store!(io:, git_sha:, sha256:, signature:, artifact_name:, version: nil, full_git_sha: nil, built_at: nil)
    git_sha = validated_git_sha(git_sha)
    raise ArgumentError, "artifact_name is invalid" unless artifact_name.to_s.match?(ARTIFACT_NAME_PATTERN)
    raise ArgumentError, "artifact_signature is required" if signature.blank?

    data = io.read
    actual = Digest::SHA256.hexdigest(data)
    unless ActiveSupport::SecurityUtils.secure_compare(actual, sha256.to_s.downcase)
      raise DigestMismatch, "uploaded artifact does not match artifact_sha256"
    end

    ActiveStorage::Blob.find_by(key: key(git_sha))&.purge
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(data),
      key: key(git_sha),
      filename: artifact_name.to_s,
      content_type: "application/gzip",
      metadata: {
        "git_sha" => git_sha,
        "full_git_sha" => full_git_sha.presence,
        "version" => version.presence,
        "sha256" => actual,
        "signature" => signature.to_s.strip,
        "built_at" => built_at.presence
      }.compact,
      service_name: ActiveStorage::Blob.service.name
    )
  end

  # Makes an uploaded release the one every Mac worker should run.
  def self.activate!(git_sha:, base_url:)
    git_sha = validated_git_sha(git_sha)
    blob = blob_for(git_sha) or raise ArgumentError, "no uploaded macOS worker release for #{git_sha}"
    meta = blob.metadata.to_h

    release = {
      "git_sha" => git_sha,
      "full_git_sha" => meta["full_git_sha"],
      "version" => meta["version"],
      "artifact_url" => "#{base_url.to_s.chomp("/")}/api/v1/app/admin/macos_worker_update/artifact",
      "artifact_sha256" => meta["sha256"],
      "artifact_signature" => meta["signature"],
      "artifact_name" => blob.filename.to_s,
      "built_at" => meta["built_at"],
      "rollout" => ROLLOUT_IMMEDIATE,
      "poll_interval_seconds" => POLL_INTERVAL_SECONDS,
      "activated_at" => Time.current.iso8601
    }.compact
    AppSetting.current.update!(macos_worker_desired_release: release)
    release
  end

  def self.blob_for(git_sha)
    ActiveStorage::Blob.find_by(key: key(git_sha))
  end

  def self.key(git_sha)
    "macos-worker/releases/#{git_sha}"
  end

  # Where every Mac worker stands relative to the active release.
  def self.status(now: Time.current)
    desired = AppSetting.macos_worker_desired_release
    desired_sha = desired["git_sha"].presence
    live = InstanceVersion.fresh.where(role: "worker").order(:hostname).select { |instance| macos_worker?(instance) }
    live_hostnames = live.map(&:hostname)
    offline = InstanceVersion.where(role: "worker")
      .where(last_heartbeat_at: (now - OFFLINE_WINDOW)..)
      .where.not(hostname: live_hostnames)
      .order(:hostname)
      .select { |instance| macos_worker?(instance) }
      .uniq(&:hostname)

    {
      desired_git_sha: desired_sha,
      rollout: desired["rollout"],
      activated_at: desired["activated_at"],
      workers: live.map { |instance| worker_status(instance, desired_sha, live: true) } +
        offline.map { |instance| worker_status(instance, desired_sha, live: false) }
    }
  end

  def self.worker_status(instance, desired_sha, live:)
    updater = instance.macos_updater_status.to_h
    # The worker's own heartbeat keeps reporting the old revision while it
    # drains in-flight runs after the updater activated the new release; it
    # restarts on the new one when they finish and takes no new work until
    # then (see RunJob's version-skew deferral), so either signal counts.
    activated = updater["state"].to_s != "failed" && same_revision?(updater["current_version"], desired_sha)
    {
      hostname: instance.hostname,
      live: live,
      version: instance.version,
      current: desired_sha.present? && (same_revision?(instance.version, desired_sha) || activated),
      updater_state: updater["state"],
      updater_version: updater["current_version"],
      updater_message: updater["message"],
      updater_target_version: updater["target_version"],
      last_heartbeat_at: instance.last_heartbeat_at&.iso8601
    }
  end

  def self.validated_git_sha(git_sha)
    value = git_sha.to_s.downcase
    raise ArgumentError, "git_sha must be a 7-40 character hex git SHA" unless value.match?(GIT_SHA_PATTERN)

    value
  end
  private_class_method :validated_git_sha, :worker_status
end
