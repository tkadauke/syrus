module RuntimeImages
  module Builds
    # State machine for build requests. Every mutation takes a row lock on the
    # request, re-reads state, and writes the request, attempt, and (for
    # terminal states) result together, so a worker crash, a cancel, and a lease
    # reaper racing each other cannot leave them disagreeing.
    class Orchestrator
      ORPHANED_MESSAGE = "build lost its attempt".freeze # operator-facing diagnostic text, stored in the request record
      # Creates a request, or returns the live/finished one for the same tuple.
      #  - a live request (queued/building/verifying) is returned as-is;
      #  - a request that already produced a still-pullable image is returned
      #    as-is, so callers get the existing image instead of rebuilding;
      #  - anything else (failed, canceled, rejected, revoked image) starts a
      #    fresh request, because a prior failure must not block a rebuild.
      # A capture or request that can never be built is recorded as rejected.
      def submit(namespace:, source:, recipe:, platform:, requester_kind:, requester_ref:, source_archive: nil)
        recipe = Hash(recipe).deep_stringify_keys
        rejection = rejection_for(source, recipe, platform)
        return reject(namespace, source, recipe, platform, requester_kind, requester_ref, rejection) if rejection

        recipe_digest = digest_of(recipe)
        key = RuntimeImageBuildRequest.dedup_key_for(namespace_id: namespace.id, source_digest: source.digest,
                                                     recipe_digest: recipe_digest, platform: platform)
        existing = reusable(key)
        return duplicate(existing) if existing

        request = RuntimeImageBuildRequest.new(
          runtime_image_namespace: namespace, platform: platform, dedup_key: key,
          source_kind: source.kind, source_ref: source.ref, source_digest: source.digest, source_manifest: source.manifest,
          recipe_digest: recipe_digest, recipe: recipe, requester_kind: requester_kind.to_s, requester_ref: requester_ref.to_s,
          max_attempts: Config.max_attempts
        )
        request.source_archive.attach(source_archive) if source_archive
        request.save!
        Audit.record("build.queued", outcome: "ok", namespace: namespace, actor: request.requester_kind, details: audit_details(request))
        request
      rescue ActiveRecord::RecordNotUnique
        # Lost the race against a concurrent submitter of the same tuple.
        existing = reusable(key)
        existing ? duplicate(existing) : raise
      end

      # Claims the next startable request that fits under the concurrency caps
      # and starts attempt N. Returns [request, attempt] or nil.
      def claim_next(worker: Socket.gethostname, now: Time.current)
        return nil unless Builds.builder_available?

        RuntimeImageBuildRequest.startable(now).limit(50).each do |candidate|
          claimed = claim(candidate.id, worker: worker, now: now)
          return claimed if claimed
        end
        nil
      end

      def claim(request_id, worker: Socket.gethostname, now: Time.current)
        request = RuntimeImageBuildRequest.find(request_id)
        # The instance-wide AppSetting row serializes every claim, so the
        # global cap cannot be oversubscribed by claimers in different
        # namespaces (two dispatch runs can overlap); the namespace row then
        # serializes that namespace's cap (formal/SyrusModel/BuildAdmission.lean).
        AppSetting.current.with_lock do
          request.runtime_image_namespace.with_lock do
            request.with_lock do
              next nil unless request.queued? && !request.cancel_requested?
              next nil if request.next_attempt_at && request.next_attempt_at > now
              next nil if capacity_exhausted?(request)

              attempt = request.attempts.create!(number: request.attempts_count + 1, state: "building", worker_hostname: worker,
                                                 started_at: now, lease_expires_at: now + Config.lease_duration)
              request.transition_to!("building", attempts_count: attempt.number, started_at: request.started_at || now, next_attempt_at: nil)
              [ request, attempt ]
            end
          end
        end
      end

      # Marks an attempt as being executed by exactly one job delivery. A
      # duplicate delivery (queue redelivery, retried enqueue) finds the mark
      # and must not run the build again; a lost worker is handled by the lease
      # reaper, which starts a new attempt rather than re-running this one.
      def begin_execution(attempt, now: Time.current)
        locked(attempt) do |request, attempt|
          next false unless attempt.active? && request.in_flight?

          if attempt.execution_started_at
            Telemetry.recovery("duplicate_delivery")
            next false
          end
          attempt.update!(execution_started_at: now)
          true
        end
      end

      def begin_verifying(attempt, now: Time.current)
        locked(attempt) do |request, attempt|
          next false unless attempt.state == "building" && request.building?

          attempt.update!(state: "verifying", lease_expires_at: now + Config.lease_duration)
          request.transition_to!("verifying")
          true
        end
      end

      # Extends the lease of a healthy long-running attempt.
      def heartbeat(attempt, now: Time.current)
        locked(attempt) do |_request, attempt|
          next false unless attempt.active?

          attempt.update!(lease_expires_at: now + Config.lease_duration)
          true
        end
      end

      def succeed(attempt, image:, now: Time.current)
        locked(attempt) do |request, attempt|
          next request.result unless request.in_flight? && attempt.active?
          image.with_lock do
            raise BuildFailed.new("image #{image.digest} has no accepted verification attempt", code: "verification_incomplete") unless image.verified_candidate?

            if request.cancel_requested?
              attempt.update!(state: "canceled", finished_at: now, lease_expires_at: nil)
              next cancel_now(request, now: now)
            end

            attempt.update!(state: "succeeded", finished_at: now, lease_expires_at: nil)
            Telemetry.attempt("succeeded")
            request.transition_to!("succeeded", finished_at: now)
            finish(request, outcome: "succeeded", image: image, digest: image.digest, now: now)
          end
        end
      end

      # Records a failed attempt. A retryable failure with attempts left
      # re-queues the request with backoff; otherwise it is terminal.
      def fail_attempt(attempt, code:, detail:, retryable:, now: Time.current)
        locked(attempt) do |request, attempt|
          next request.result unless request.in_flight? && attempt.active?

          attempt.update!(state: "failed", finished_at: now, lease_expires_at: nil, error_code: code.to_s,
                          error_message: detail.to_s.truncate(500), retryable: retryable)
          if request.cancel_requested?
            Telemetry.attempt("canceled", code)
            cancel_now(request, now: now)
          elsif retryable && !request.attempts_exhausted?
            Telemetry.attempt("retried", code)
            request.transition_to!("queued", next_attempt_at: now + Config.retry_delay(request.attempts_count, code: code))
            Audit.record("build.retry", outcome: "ok", namespace: request.runtime_image_namespace, details: audit_details(request).merge("error_code" => code.to_s))
            nil
          else
            Telemetry.attempt("failed", code)
            request.transition_to!("failed", finished_at: now)
            finish(request, outcome: "failed", error_code: code.to_s, message: detail, now: now)
          end
        end
      end

      # Cancels a request. Queued requests cancel immediately; in-flight ones
      # are flagged and cancel when the builder next observes it (or when its
      # attempt fails or its lease expires).
      def cancel(request, reason: nil, actor: "system", now: Time.current)
        request.with_lock do
          next request if request.terminal?

          request.update!(cancel_requested_at: request.cancel_requested_at || now, cancel_reason: reason.to_s.truncate(500).presence)
          cancel_now(request, now: now) if request.queued?
          request
        end
      end

      # Completes cancellation for an in-flight attempt that observed the flag.
      def acknowledge_cancel(attempt, now: Time.current)
        locked(attempt) do |request, attempt|
          next request.result unless request.in_flight? && attempt.active?

          attempt.update!(state: "canceled", finished_at: now, lease_expires_at: nil)
          Telemetry.attempt("canceled")
          cancel_now(request, now: now)
        end
      end

      def cancel_requested?(request) = RuntimeImageBuildRequest.where(id: request.id).where.not(cancel_requested_at: nil).exists?

      # Fails attempts that can no longer be trusted: the worker stopped
      # heartbeating (lease expired), or the attempt has outlived the hard
      # runtime ceiling even though something keeps renewing its lease. Both are
      # retryable: neither says anything about the build itself.
      def reap_expired(now: Time.current)
        expired = RuntimeImageBuildAttempt.lease_expired(now).includes(:request).to_a
        overdue = RuntimeImageBuildAttempt.overdue(now).includes(:request).where.not(id: expired.map(&:id)).to_a
        expired.map { |attempt| reap(attempt, "lease_expired", "build worker stopped reporting progress", now) } +
          overdue.map { |attempt| reap(attempt, "attempt_deadline_exceeded", "attempt exceeded #{Config.max_attempt_runtime.to_i}s", now) }
      end

      # Repairs requests that say they are in flight but have no active
      # attempt (a crash between two writes, a manual edit) and queued requests
      # that carry a cancellation nobody completed. Returns the repaired requests.
      def reap_orphans(now: Time.current)
        with_attempt = RuntimeImageBuildAttempt.active.select(:runtime_image_build_request_id)
        candidates = RuntimeImageBuildRequest.in_flight.where.not(id: with_attempt).or(
          RuntimeImageBuildRequest.queued.where.not(cancel_requested_at: nil)
        )
        candidates.filter_map { |candidate| repair_orphan(candidate.id, now) }
      end

      # The recovery pass the dispatcher runs before admitting new work.
      def recover(now: Time.current)
        { attempts: reap_expired(now: now), orphans: reap_orphans(now: now) }
      end

      private

      def reap(attempt, code, detail, now)
        Telemetry.recovery(code)
        fail_attempt(attempt, code: code, detail: detail, retryable: true, now: now)
        attempt
      end

      def repair_orphan(request_id, now)
        request = RuntimeImageBuildRequest.find(request_id)
        request.with_lock do
          next nil if request.terminal? || RuntimeImageBuildAttempt.active.exists?(runtime_image_build_request_id: request.id)

          Telemetry.recovery("orphaned_request")
          Audit.record("build.recovered", outcome: "repaired", namespace: request.runtime_image_namespace,
                                          details: audit_details(request).merge("state" => request.state))
          if request.cancel_requested?
            cancel_now(request, now: now)
          elsif request.queued?
            next nil
          elsif request.attempts_exhausted?
            request.transition_to!("failed", finished_at: now)
            finish(request, outcome: "failed", error_code: "orphaned_request", message: ORPHANED_MESSAGE, now: now)
          else
            request.transition_to!("queued", next_attempt_at: now + Config.retry_delay(request.attempts_count))
          end
          request
        end
      end

      def duplicate(request)
        Telemetry.recovery("duplicate_submit")
        request
      end

      def locked(attempt)
        request = attempt.request
        request.with_lock do
          attempt.reload
          yield request, attempt
        end
      end

      def reusable(key)
        live = RuntimeImageBuildRequest.live.find_by(dedup_key: key)
        return live if live

        succeeded = RuntimeImageBuildRequest.where(dedup_key: key, state: "succeeded").order(id: :desc).includes(result: :runtime_image).first
        succeeded if succeeded&.result&.runtime_image&.pullable?
      end

      def capacity_exhausted?(request)
        in_flight = RuntimeImageBuildRequest.in_flight
        in_flight.count >= Config.max_concurrent_builds ||
          in_flight.where(runtime_image_namespace_id: request.runtime_image_namespace_id).count >= Config.max_concurrent_per_namespace
      end

      def cancel_now(request, now:)
        request.transition_to!("canceled", finished_at: now)
        finish(request, outcome: "canceled", message: request.cancel_reason || "canceled", now: now)
      end

      def finish(request, outcome:, now:, image: nil, digest: nil, error_code: nil, message: nil)
        result = RuntimeImageBuildResult.create!(
          request: request, outcome: outcome, runtime_image: image, digest: digest, error_code: error_code,
          message: message.to_s.truncate(500).presence, attempts_used: request.attempts_count, finished_at: now
        )
        Audit.record("build.#{outcome}", outcome: outcome == "succeeded" ? "ok" : "failed", image: image,
                     namespace: request.runtime_image_namespace, digest: digest, details: audit_details(request).merge("error_code" => error_code))
        result
      end

      def reject(namespace, source, recipe, platform, requester_kind, requester_ref, rejection)
        request = RuntimeImageBuildRequest.new(
          runtime_image_namespace: namespace, platform: platform.to_s.presence || "unknown", state: "rejected",
          dedup_key: SecureRandom.hex(32), source_kind: source&.kind.presence || "unknown", source_ref: source&.ref.presence || "unknown",
          source_digest: source&.digest || "sha256:#{"0" * 64}", source_manifest: source&.manifest || {},
          recipe_digest: "sha256:#{"0" * 64}", recipe: {}, requester_kind: requester_kind.to_s, requester_ref: requester_ref.to_s,
          max_attempts: 1, finished_at: Time.current
        )
        request.save!
        finish(request, outcome: "rejected", error_code: rejection.code, message: rejection.message, now: request.finished_at)
        request
      end

      def rejection_for(source, recipe, platform)
        return Rejected.new("source_invalid", "source capture is required") unless source
        return Rejected.new("platform_unsupported", "unsupported platform #{platform.inspect}") unless Config::PLATFORMS.include?(platform)
        return Rejected.new("recipe_too_large", "recipe exceeds #{Config::MAX_RECIPE_BYTES} bytes") if SourceCapture.canonical_json(recipe).bytesize > Config::MAX_RECIPE_BYTES

        nil
      end

      def digest_of(recipe) = "sha256:#{Digest::SHA256.hexdigest(SourceCapture.canonical_json(recipe))}"

      def audit_details(request) = { "request_id" => request.id, "attempts" => request.attempts_count, "platform" => request.platform }
    end
  end
end
