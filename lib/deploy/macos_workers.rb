# frozen_string_literal: true

require "digest"
require "json"
require "tempfile"

module Deploy
  # Every deploy updates the native macOS workers to the revision it rolls out.
  #
  # Mac hosts run outside the cluster, so nothing else ever moved them, and a
  # Mac worker left on the previous revision ran its code against the schema
  # the deploy had just migrated. Three steps, each at the point where it is
  # safe:
  #
  #   prepare!   before any cluster changes: build the source artifact for this
  #              revision, sign it, and upload it to the production Syrus. A
  #              failure here aborts the deploy with every cluster untouched.
  #
  #   activate!  right after production's migrations: make it the release
  #              every Mac worker must run. From here a Mac worker on another
  #              revision takes no new work (RunJob and RunQueueResolver hold
  #              it back) until its updater has installed this one.
  #
  #   await!     after every cluster converged: wait until each live Mac worker
  #              reports the revision. A Mac that does not catch up fails the
  #              deploy, but nothing is rolled back -- the cluster rollout
  #              stands, and the skew guard keeps the Mac idle until it does.
  #
  # The first deploy of this phase talks to a production Syrus that predates
  # the release endpoints; the upload is then retried once the cluster runs
  # the new revision, before waiting.
  class MacosWorkers
    API_PATH = "/api/v1/admin/macos_worker_releases"

    def initialize(config:, repo:, shell:, reporter:, waiter:)
      @config = config
      @repo = repo
      @shell = shell
      @reporter = reporter
      @waiter = waiter
      @uploaded = false
      @activated = false
    end

    def enabled?
      config.macos_workers? && config.clusters.any? { |cluster| cluster.label == config.macos_workers_cluster }
    end

    def prepare!
      return unless enabled?

      reporter.step("macOS workers: building and signing the release for #{sha}")
      check_prerequisites!
      @artifact = build!
      @uploaded = upload!(tolerate_missing_endpoint: true)
    end

    def activate!
      return unless enabled?
      return reporter.warn("macOS workers: production predates release endpoints; activating after the rollout") unless @uploaded

      activate_release!
    end

    def await!
      return unless enabled?

      unless @uploaded
        @uploaded = upload!(tolerate_missing_endpoint: false)
        activate_release!
      end
      activate_release! unless @activated

      reporter.step("macOS workers: waiting for every live Mac worker to run #{sha}")
      return reporter.ok("macOS workers: dry run, not waiting") if shell.dry_run?

      verdict = nil
      waiter.until(label: "macOS workers on #{sha}", timeout: config.macos_worker_update_timeout,
                   poll: config.macos_worker_update_poll_interval, report_every: 60) do
        verdict = readiness
      end
      reporter.ok("macOS workers: #{verdict.note}")
    rescue Failure => e
      raise Failure.new(
        "#{e.message} -- the cluster rollout stands; Mac workers on another revision take no work until they update",
        detail: e.detail
      )
    end

    private

    attr_reader :config, :repo, :shell, :reporter, :waiter

    def sha = repo.sha

    def check_prerequisites!
      missing = []
      missing << "SYRUS_APP_HOST (the production Syrus URL)" if config.macos_app_host.to_s.empty?
      missing << "an API token (SYRUS_API_TOKEN or #{config.macos_api_token_file})" if api_token.to_s.empty?
      unless File.file?(config.macos_signing_key_file)
        missing << "the release signing key at #{config.macos_signing_key_file} (SYRUS_MACOS_UPDATE_SIGNING_KEY_FILE)"
      end
      return if missing.empty?

      raise UsageError.new(
        "macOS workers: cannot publish the Mac worker release; missing #{missing.join(", ")}",
        detail: "Every deploy updates the native macOS workers. Set SYRUS_DEPLOY_MACOS_WORKERS=0 only for an " \
                "installation without Mac workers."
      )
    end

    Artifact = Struct.new(:path, :sha256, :signature_path, keyword_init: true)

    def build!
      version = "v0.0.0-deploy.#{sha}"
      result = shell.stream_write(
        [ "bin/release-macos-worker", version ],
        # Build the commit this deploy started from, not whatever HEAD is now:
        # another session committing mid-deploy otherwise changed the release.
        env: { "SYRUS_MACOS_UPDATE_SIGNING_KEY_FILE" => config.macos_signing_key_file, "SYRUS_RELEASE_GIT_REF" => sha }
      )
      raise Failure.new("macOS workers: building the release artifact failed") unless result.success?

      dir = File.join(repo_root, "dist", "releases", version, "macos-worker")
      path = File.join(dir, "syrus-worker-macos-arm64-#{sha}.tar.gz")
      return Artifact.new(path: path, sha256: "<sha256>", signature_path: "#{path}.sig") if shell.dry_run?

      raise Failure.new("macOS workers: expected artifact #{path} was not built") unless File.file?(path)
      raise Failure.new("macOS workers: the artifact was not signed") unless File.file?("#{path}.sig")

      Artifact.new(path: path, sha256: Digest::SHA256.file(path).hexdigest, signature_path: "#{path}.sig")
    end

    def upload!(tolerate_missing_endpoint:)
      code, body = api_call(:write, "POST", "", form: {
        "artifact" => "@#{@artifact.path};type=application/gzip",
        "git_sha" => sha,
        "artifact_sha256" => @artifact.sha256,
        "artifact_signature" => "<#{@artifact.signature_path}",
        "artifact_name" => File.basename(@artifact.path)
      })
      return true if code.between?(200, 299)
      return false if code == 404 && tolerate_missing_endpoint

      raise Failure.new("macOS workers: uploading the release failed (HTTP #{code})", detail: body)
    end

    def activate_release!
      code, body = api_call(:write, "POST", "/activate", form: { "git_sha" => sha })
      raise Failure.new("macOS workers: activating the release failed (HTTP #{code})", detail: body) unless code.between?(200, 299)

      @activated = true
      reporter.ok("macOS workers: release #{sha} is active; Mac workers update now")
    end

    def readiness
      code, body = api_call(:read, "GET", "/status")
      return Waiter.pending("status request failed (HTTP #{code})") unless code.between?(200, 299)

      status = JSON.parse(body)
      workers = Array(status["workers"])
      live = workers.select { |worker| worker["live"] }
      offline = workers.reject { |worker| worker["live"] }.map { |worker| worker["hostname"] }
      offline_note = offline.empty? ? "" : "; offline, will update when back: #{offline.join(", ")}"

      return Waiter.converged("no live Mac workers#{offline_note}") if live.empty?

      failed = live.select { |worker| worker["updater_state"] == "failed" && !worker["current"] }
      unless failed.empty?
        return Waiter.failed(
          "update failed on #{failed.map { |w| w["hostname"] }.join(", ")}",
          detail: failed.map { |w| "#{w["hostname"]}: #{w["updater_message"]}" }.join("\n")
        )
      end

      behind = live.reject { |worker| worker["current"] }
      if behind.empty?
        Waiter.converged("#{live.size} live Mac worker(s) on #{sha}#{offline_note}")
      else
        Waiter.pending(
          "waiting for #{behind.map { |w| "#{w["hostname"]} (#{w["updater_state"] || "no report"}, on #{w["version"]})" }.join(", ")}"
        )
      end
    rescue JSON::ParserError
      Waiter.pending("status response was not JSON")
    end

    # curl keeps the HTTP plumbing in the command stream a dry run records.
    # The token travels in a header file, so it never appears in an argv.
    def api_call(mode, verb, path, form: nil)
      header = Tempfile.new([ "syrus-deploy-auth", ".txt" ])
      header.write("Authorization: Bearer #{api_token}\n")
      header.flush
      argv = [ "curl", "-sS", "--max-time", "300", "-X", verb, "-H", "@#{header.path}",
               "-w", "\n%{http_code}" ]
      form&.each { |key, value| argv.push("-F", "#{key}=#{value}") }
      argv << "#{config.macos_app_host.chomp("/")}#{API_PATH}#{path}"

      result = mode == :write ? shell.write(argv) : shell.read(argv)
      return [ 200, "{}" ] if shell.dry_run? && mode == :write

      body, _, code = result.stdout.to_s.rpartition("\n")
      [ Integer(code.strip, 10, exception: false) || 0, body ]
    ensure
      header&.close!
    end

    def api_token
      @api_token ||= config.macos_api_token
    end

    def repo_root
      repo.toplevel
    end
  end
end
