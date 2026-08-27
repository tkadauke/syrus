require "puma"
require "json"

module GitHistory
  # Internal-only HTTP control surface for git-history bare-clone reads.
  #
  # `RepositoryBareClone#sync!` only ever runs from PollMergeStateJob /
  # PollPullRequestJob / LandingQueueRecheck — all processed by `bin/jobs`,
  # i.e. worker pods, which are the only pods with the `$SYRUS_DATA_ROOT` PVC
  # mounted. `Api::V1::App::GitHistoryController` is served by web pods, which
  # do not share that filesystem, so it cannot read `RepositoryBareClone`
  # directly. This server runs inside a worker process — where the bare clone
  # actually lives on disk — and answers git-log reads over HTTP instead. See
  # GitHistory::RelayClient for the web-process caller.
  #
  # Mirrors PreviewControlServer's shape: fixed port via env var, bound on the
  # internal network only, never exposed through public ingress. No
  # per-request credential — GitHistoryController already authorizes the
  # request (`Repository.accessible_to(Current.user)`) before proxying.
  #
  # Latent single-writer-pod assumption: today exactly one worker pod ever
  # syncs bare clones, because `polling` is conventionally bundled onto the
  # single "home" worker (`config/queue.home.yml`; see
  # `config/syrus_docs/multi_worker.md`'s "never scale the home worker past
  # one replica"). Nothing in code enforces or records this the way
  # `ChatSession#coding_relay_address` records which pod holds a specific live
  # checkout — this relay must run on the same worker pod(s) that process the
  # `polling` queue, or reads may silently serve stale/inconsistent history
  # depending on which pod happens to answer.
  class RelayServer
    DEFAULT_PORT = 4571
    PORT = Integer(ENV.fetch("SYRUS_GIT_HISTORY_RELAY_PORT", DEFAULT_PORT))
    HOST = "0.0.0.0"

    AVAILABLE_PATH = %r{\A/repositories/(\d+)/available\z}
    COMMITS_PATH = %r{\A/repositories/(\d+)/commits\z}

    class << self
      def start(host: HOST, port: PORT)
        new(host: host, port: port).tap(&:start)
      end

      # Idempotent boot-time entry point: starts the relay once per worker
      # process and tolerates the port already being bound from a previous
      # Zeitwerk dev-reload cycle — the old server thread is still running
      # and still serving requests.
      def ensure_running!(host: HOST, port: PORT)
        return @instance if @instance

        @instance = start(host: host, port: port)
      rescue Errno::EADDRINUSE
        @instance
      end
    end

    def initialize(host: HOST, port: PORT)
      @host = host
      @port = port
    end

    def start
      @server = Puma::Server.new(method(:call))
      @server.add_tcp_listener(@host, @port)
      @server.run(true, thread_name: "git-history-relay")
      Rails.logger.info("[GitHistory::RelayServer] listening on #{@host}:#{@port}")
      self
    end

    def stop
      return unless @server

      @server.stop(true)
      Rails.logger.info("[GitHistory::RelayServer] stopped")
    end

    def call(env)
      request = Rack::Request.new(env)
      return not_found unless request.get?

      if (match = AVAILABLE_PATH.match(request.path))
        available_response(match[1].to_i)
      elsif (match = COMMITS_PATH.match(request.path))
        commits_response(match[1].to_i, request.params["cursor"], request.params["limit"])
      else
        not_found
      end
    rescue StandardError => e
      Rails.logger.error("[GitHistory::RelayServer] #{e.class}: #{e.message}")
      json_response(500, error: "internal_error")
    end

    private

    def available_response(repository_id)
      repository = find_repository(repository_id)
      return not_found unless repository

      json_response(200, available: CommitLog.new(repository: repository).available?)
    end

    def commits_response(repository_id, cursor, limit)
      repository = find_repository(repository_id)
      return not_found unless repository

      page = CommitLog.new(repository: repository).fetch(cursor: cursor.presence, limit: limit.to_i)
      json_response(200, entries: page.entries, has_more: page.has_more)
    end

    def find_repository(repository_id)
      with_connection { Repository.find_by(id: repository_id) }
    end

    def not_found
      json_response(404, error: "not_found")
    end

    def json_response(status, payload)
      [ status, { "Content-Type" => "application/json" }, [ JSON.generate(payload) ] ]
    end

    def with_connection(&block)
      ActiveRecord::Base.connection_pool.with_connection(&block)
    end
  end
end
