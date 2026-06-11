# frozen_string_literal: true

require "io/console"
require "json"
require "net/http"
require "open3"
require "optparse"
require "pathname"
require "shellwords"
require "time"
require "uri"
require "yaml"

module SyrusCli
  class Error < StandardError; end

  TERMINAL_JOB_STATES = %w[closed failed cancelled].freeze
  TERMINAL_RUN_STATES = %w[succeeded failed cancelled].freeze
  STATE_COLORS = {
    "queued" => 36,
    "running" => 34,
    "succeeded" => 32,
    "closed" => 32,
    "approved" => 32,
    "failed" => 31,
    "cancelled" => 31,
    "blocked_by_epic" => 33,
    "triaging" => 33
  }.freeze

  Config = Struct.new(:instance_url, :api_token, :github_token, keyword_init: true) do
    def token_suffix
      token = api_token.to_s
      token.empty? ? "none" : token[-4, 4]
    end
  end

  class << self
    def run(argv = ARGV, out: $stdout, err: $stderr)
      CLI.new(out: out, err: err).run(argv)
    rescue Error => e
      err.puts "syrus: #{e.message}"
      1
    rescue Interrupt
      err.puts
      130
    end
  end

  class CLI
    def initialize(out:, err:, http_client: nil, sleep_proc: nil, pager: nil, repo_detector: nil)
      @out = out
      @err = err
      @http = http_client || HttpClient.new
      @sleep = sleep_proc || Kernel.method(:sleep)
      @pager = pager || Pager.new
      @repo_detector = repo_detector || RepoDetector.new
    end

    def run(argv)
      command = argv.shift
      case command
      when "job" then job(argv)
      when "epic" then epic(argv)
      when "repo" then repo(argv)
      when "whoami" then whoami(argv)
      when "-h", "--help", nil then help
      else
        raise Error, "unknown command #{command.inspect}"
      end
      0
    end

    private

    attr_reader :out, :err

    def job(argv)
      subcommand = argv.shift
      case subcommand
      when "list" then job_list(argv)
      when "search" then job_search(argv)
      when "show" then job_show(argv)
      when "log" then job_log(argv)
      when "watch" then job_watch(argv)
      when "diff" then job_diff(argv)
      else
        raise Error, "usage: syrus job list|search|show|log|watch|diff"
      end
    end

    def epic(argv)
      subcommand = argv.shift
      case subcommand
      when "list" then epic_list(argv)
      when "search" then epic_search(argv)
      when "show" then epic_show(argv)
      else
        raise Error, "usage: syrus epic list|search|show"
      end
    end

    def repo(argv)
      subcommand = argv.shift
      case subcommand
      when "list" then repo_list(argv)
      else
        raise Error, "usage: syrus repo list"
      end
    end

    def job_list(argv)
      options = { state: "open", limit: 20 }
      OptionParser.new do |opts|
        opts.on("--state STATE", %w[open closed all]) { |value| options[:state] = value }
        opts.on("--limit N", Integer) { |value| options[:limit] = value }
      end.parse!(argv)
      rows = fetch_jobs(state: options[:state], limit: options[:limit])
      print_jobs_table(rows)
    end

    def job_search(argv)
      options = { state: "open", limit: 20 }
      OptionParser.new do |opts|
        opts.on("--state STATE", %w[open closed all]) { |value| options[:state] = value }
        opts.on("--limit N", Integer) { |value| options[:limit] = value }
      end.parse!(argv)
      query = argv.join(" ").strip
      raise Error, "usage: syrus job search QUERY" if query.empty?

      rows = fetch_jobs(state: options[:state], limit: 50)
        .select { |job| job_title(job).downcase.include?(query.downcase) }
        .first(options[:limit])
      print_jobs_table(rows)
    end

    def job_show(argv)
      id = required_id(argv, "syrus job show JOB-ID")
      payload = api_get("/api/v1/admin/jobs/#{id}")
      latest_run = latest_run(payload)
      log_lines = latest_run ? transcript_lines(latest_run.fetch("id")).last(10) : []

      out.puts "Job ##{payload.fetch("id")}: #{payload["issue_title"]}"
      out.puts "State: #{payload["state"]}"
      out.puts "Repository: #{payload.dig("repository", "slug")}"
      out.puts "PR: #{pr_text(payload)}"
      out.puts "Created: #{payload["created_at"]}"
      out.puts "Updated: #{payload["updated_at"]}"
      out.puts "Started: #{payload["started_at"] || "-"}"
      out.puts "Finished: #{payload["finished_at"] || "-"}"
      out.puts "Current step: #{current_step_text(payload)}"
      out.puts
      out.puts "Last log lines:"
      if log_lines.empty?
        out.puts "  none"
      else
        log_lines.each { |line| out.puts "  #{line}" }
      end
    end

    def job_log(argv)
      id = required_id(argv, "syrus job log JOB-ID")
      payload = api_get("/api/v1/admin/jobs/#{id}")
      run = latest_run(payload)
      raise Error, "Job ##{id} has no runs yet" unless run

      if TERMINAL_RUN_STATES.include?(run["state"].to_s)
        @pager.write(transcript_lines(run.fetch("id")).join("\n") + "\n")
        return
      end

      seen = 0
      loop do
        payload = api_get("/api/v1/admin/jobs/#{id}")
        run = latest_run(payload)
        lines = run ? transcript_lines(run.fetch("id")) : []
        lines.drop(seen).each { |line| out.puts line }
        seen = lines.size
        break if job_done?(payload) || run.nil? || TERMINAL_RUN_STATES.include?(run["state"].to_s)

        @sleep.call(2)
      end
    end

    def job_watch(argv)
      id = required_id(argv, "syrus job watch JOB-ID")
      first = true
      loop do
        payload = api_get("/api/v1/admin/jobs/#{id}")
        out.print "\e[H\e[2J" unless first
        first = false
        render_job_watch(payload)
        break if job_done?(payload)

        @sleep.call(3)
      end
    end

    def job_diff(argv)
      id = required_id(argv, "syrus job diff JOB-ID")
      payload = api_get("/api/v1/admin/jobs/#{id}")
      pr = payload["pr_number"] || payload["external_pr_number"]
      raise Error, "Job ##{id} has no pull request" unless pr

      repo = payload.dig("repository", "slug")
      url = "https://github.com/#{repo}/pull/#{pr}"
      github_token = config.github_token.to_s
      if github_token.empty?
        out.puts url
        return
      end

      diff = @http.get_raw(
        URI("https://api.github.com/repos/#{repo}/pulls/#{pr}"),
        headers: {
          "Authorization" => "Bearer #{github_token}",
          "Accept" => "application/vnd.github.diff",
          "User-Agent" => "syrus-cli"
        }
      )
      @pager.write(diff)
    end

    def epic_list(argv)
      options = { limit: 20 }
      OptionParser.new { |opts| opts.on("--limit N", Integer) { |value| options[:limit] = value } }.parse!(argv)
      print_epics_table(fetch_epics(limit: options[:limit]))
    end

    def epic_search(argv)
      options = { limit: 20 }
      OptionParser.new { |opts| opts.on("--limit N", Integer) { |value| options[:limit] = value } }.parse!(argv)
      query = argv.join(" ").strip
      raise Error, "usage: syrus epic search QUERY" if query.empty?

      rows = fetch_epics(limit: 50).select { |epic| epic["title"].to_s.downcase.include?(query.downcase) }.first(options[:limit])
      print_epics_table(rows)
    end

    def epic_show(argv)
      id = required_id(argv, "syrus epic show EPIC-ID")
      payload = api_get("/api/v1/admin/epics/#{id}")
      out.puts "Epic ##{payload.fetch("id")}: #{payload["title"]}"
      out.puts "State: #{payload["state"]}"
      out.puts "Repository: #{payload.dig("repository", "slug")}"
      out.puts "GitHub issue: #{payload["github_issue_url"] || "-"}"
      out.puts
      print_jobs_table(payload.fetch("jobs", []))
    end

    def repo_list(_argv)
      payload = api_get("/api/v1/admin/repositories")
      rows = payload.fetch("repositories")
      print_table(
        [ "REPO", "ACTIVE JOBS", "LAST JOB" ],
        rows.map do |repo|
          [
            repo.fetch("slug"),
            repo.fetch("active_jobs").to_s,
            repo["last_job"] ? "##{repo.dig("last_job", "id")} #{repo.dig("last_job", "title")}" : "-"
          ]
        end
      )
    end

    def whoami(_argv)
      payload = api_get("/api/v1/admin/whoami")
      out.puts "Email: #{payload.dig("user", "email_address")}"
      out.puts "Instance: #{config.instance_url}"
      out.puts "Token: ...#{config.token_suffix}"
    end

    def help
      out.puts <<~TEXT
        Usage: syrus COMMAND

          syrus job list [--state open|closed|all] [--limit N]
          syrus job search QUERY
          syrus job show JOB-ID
          syrus job log JOB-ID
          syrus job watch JOB-ID
          syrus job diff JOB-ID
          syrus epic list
          syrus epic search QUERY
          syrus epic show EPIC-ID
          syrus repo list
          syrus whoami
      TEXT
    end

    def fetch_jobs(state:, limit:)
      params = {}
      params[:state] = state unless state == "all"
      params[:repo] = current_repo if current_repo
      api_get("/api/v1/admin/jobs", params: params).fetch("jobs").first(limit)
    end

    def fetch_epics(limit:)
      params = {}
      params[:repo] = current_repo if current_repo
      epics = api_get("/api/v1/admin/epics", params: params).fetch("epics").first(limit)
      epics.map do |epic|
        detail = api_get("/api/v1/admin/epics/#{epic.fetch("id")}")
        epic.merge("jobs" => detail.fetch("jobs", []))
      rescue Error
        epic
      end
    end

    def current_repo
      @current_repo ||= @repo_detector.slug
    end

    def config
      @config ||= ConfigLoader.load
    end

    def api_get(path, params: {})
      uri = URI.join("#{config.instance_url}/", path.sub(%r{\A/}, ""))
      uri.query = URI.encode_www_form(params) if params.any?
      @http.get_json(uri, token: config.api_token)
    end

    def required_id(argv, usage)
      id = argv.shift
      raise Error, "usage: #{usage}" if id.to_s.empty?

      id
    end

    def print_jobs_table(jobs)
      terminal_width = IO.console&.winsize&.last || 100
      fixed = 4 + 3 + 14 + 3 + 24 + 3 + 12
      title_width = [ terminal_width - fixed, 20 ].max
      print_table(
        [ "ID", "STATE", "REPO", "TITLE", "PR" ],
        jobs.map do |job|
          [
            job.fetch("id").to_s,
            color_state(job["state"]),
            job_repository(job),
            truncate(job_title(job), title_width),
            pr_text(job)
          ]
        end
      )
    end

    def print_epics_table(epics)
      print_table(
        [ "ID", "STATE", "TITLE", "JOBS" ],
        epics.map do |epic|
          jobs = epic.fetch("jobs", [])
          done = jobs.count { |job| job["state"] == "closed" }
          [
            epic.fetch("id").to_s,
            color_state(epic["state"]),
            epic["title"].to_s,
            jobs.empty? ? "0/0 done" : "#{done}/#{jobs.size} done"
          ]
        end
      )
    end

    def print_table(headers, rows)
      widths = headers.each_index.map do |index|
        ([ headers[index].length ] + rows.map { |row| strip_ansi(row[index].to_s).length }).max
      end
      out.puts headers.each_with_index.map { |header, index| header.ljust(widths[index]) }.join("  ")
      out.puts widths.map { |width| "-" * width }.join("  ")
      rows.each do |row|
        out.puts row.each_with_index.map { |cell, index| pad_ansi(cell.to_s, widths[index]) }.join("  ")
      end
    end

    def render_job_watch(payload)
      title = truncate(payload["issue_title"].to_s, 34)
      repo = payload.dig("repository", "slug")
      header = "JOB-#{payload["id"]} · #{title}     #{repo}"
      out.puts header
      out.puts "─" * strip_ansi(header).length
      latest_workflow(payload)&.fetch("steps", [])&.each do |step|
        marker = case step["state"]
                 when "succeeded" then "✓"
                 when "running" then "●"
                 when "failed" then "✗"
                 else " "
                 end
        elapsed = elapsed_text(step)
        suffix = step["state"] == "running" ? "running (#{elapsed})" : elapsed
        out.puts "#{marker} #{step["kind"].to_s.ljust(16)} #{suffix}"
      end
    end

    def latest_workflow(payload)
      payload.fetch("workflows", []).max_by { |workflow| workflow["created_at"].to_s }
    end

    def latest_run(payload)
      latest_workflow(payload)&.fetch("steps", [])&.flat_map { |step| step.fetch("runs", []) }&.max_by { |run| run["created_at"].to_s }
    end

    def current_step_text(payload)
      step = latest_workflow(payload)&.fetch("steps", [])&.find { |candidate| %w[running queued].include?(candidate["state"].to_s) }
      return "-" unless step

      "#{step["kind"]} #{step["state"]} (#{elapsed_text(step)})"
    end

    def elapsed_text(record)
      started = parse_time(record["started_at"] || record["created_at"])
      finished = parse_time(record["finished_at"]) || Time.now
      return "0:00" unless started

      seconds = [ (finished - started).to_i, 0 ].max
      "#{seconds / 60}:#{(seconds % 60).to_s.rjust(2, "0")}"
    end

    def parse_time(value)
      Time.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def transcript_lines(run_id)
      first = api_get("/api/v1/admin/runs/#{run_id}/transcript", params: { per: 500 })
      total_pages = first.dig("pagination", "total_pages").to_i
      events = first.fetch("events", [])
      (2..total_pages).each do |page|
        events.concat(api_get("/api/v1/admin/runs/#{run_id}/transcript", params: { per: 500, page: page }).fetch("events", []))
      end
      events.map { |event| event_text(event) }.compact
    end

    def event_text(event)
      data = event["data"] || {}
      text = data["text"] || data["content"] || data.dig("message", "content")
      text = text.map { |part| part["text"] }.join if text.is_a?(Array)
      compact_presence(text.to_s.strip)
    end

    def job_done?(payload)
      TERMINAL_JOB_STATES.include?(payload["state"].to_s)
    end

    def job_repository(job)
      repo = job["repository"]
      repo.is_a?(Hash) ? repo["slug"].to_s : repo.to_s
    end

    def job_title(job)
      job["issue_title"] || job["title"] || "-"
    end

    def pr_text(job)
      pr = job["pr_number"] || job["external_pr_number"]
      pr ? "PR ##{pr}" : "-"
    end

    def color_state(state)
      return state.to_s unless STDOUT.tty?

      code = STATE_COLORS[state.to_s]
      code ? "\e[#{code}m#{state}\e[0m" : state.to_s
    end

    def truncate(text, width)
      text = text.to_s.gsub(/\s+/, " ").strip
      return text if text.length <= width

      "#{text[0, width - 1]}…"
    end

    def pad_ansi(text, width)
      text + (" " * [ width - strip_ansi(text).length, 0 ].max)
    end

    def strip_ansi(text)
      text.gsub(/\e\[[0-9;]*m/, "")
    end

    def compact_presence(value)
      value unless value.to_s.empty?
    end
  end

  class ConfigLoader
    class << self
      def load
        file_config = config_files.map { |path| read_config(path) }.compact.first || {}
        instance_url = present(ENV["SYRUS_INSTANCE_URL"]) || present(ENV["SYRUS_URL"]) || present(file_config["instance_url"]) || present(file_config["url"])
        api_token = present(ENV["SYRUS_API_TOKEN"]) || present(file_config["api_token"]) || present(file_config["token"])
        github_token = present(ENV["SYRUS_GITHUB_TOKEN"]) || present(ENV["GITHUB_TOKEN"]) || present(file_config["github_token"])
        raise Error, "missing instance URL (set SYRUS_INSTANCE_URL or ~/.config/syrus/config.json)" if instance_url.to_s.empty?
        raise Error, "missing API token (set SYRUS_API_TOKEN or ~/.config/syrus/config.json)" if api_token.to_s.empty?

        Config.new(instance_url: instance_url.to_s.sub(%r{/*\z}, ""), api_token: api_token, github_token: github_token)
      end

      private

      def config_files
        home = Pathname.new(Dir.home)
        [
          Pathname.pwd.join(".syrus", "config.json"),
          Pathname.pwd.join(".syrus", "config.yml"),
          home.join(".config", "syrus", "config.json"),
          home.join(".config", "syrus", "config.yml"),
          home.join(".syrus", "config.json"),
          home.join(".syrus", "config.yml")
        ]
      end

      def read_config(path)
        return unless path.file?

        case path.extname
        when ".json" then JSON.parse(path.read)
        when ".yml", ".yaml" then YAML.safe_load(path.read) || {}
        end
      rescue JSON::ParserError, Psych::Exception => e
        raise Error, "invalid config #{path}: #{e.message}"
      end

      def present(value)
        string = value.to_s
        string.empty? ? nil : value
      end
    end
  end

  class HttpClient
    def get_json(uri, token:)
      response = request(uri, "Authorization" => "Bearer #{token}", "Accept" => "application/json")
      body = JSON.parse(response.body)
      return body if response.is_a?(Net::HTTPSuccess)

      message = body.dig("error", "message") || response.message
      raise Error, "GET #{uri.path} failed: #{message}"
    rescue JSON::ParserError
      raise Error, "GET #{uri.path} returned invalid JSON"
    end

    def get_raw(uri, headers:)
      response = request(uri, headers)
      return response.body if response.is_a?(Net::HTTPSuccess)

      raise Error, "GET #{uri} failed: #{response.code} #{response.message}"
    end

    private

    def request(uri, headers)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        request = Net::HTTP::Get.new(uri)
        headers.each { |key, value| request[key] = value }
        http.request(request)
      end
    rescue SocketError, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout => e
      raise Error, "request failed: #{e.message}"
    end
  end

  class RepoDetector
    def slug
      remote = git("remote", "get-url", "origin")
      remote = git("remote", "get-url", "upstream") if remote.to_s.empty?
      parse_slug(remote)
    end

    private

    def git(*args)
      stdout, _stderr, status = Open3.capture3("git", *args)
      status.success? ? stdout.strip : nil
    end

    def parse_slug(remote)
      return if remote.to_s.empty?

      match = remote.match(%r{github\.com[:/](?<owner>[^/]+)/(?<name>[^/]+?)(?:\.git)?\z})
      return unless match

      "#{match[:owner]}/#{match[:name]}"
    end
  end

  class Pager
    def write(text)
      pager = ENV["PAGER"].to_s
      if !pager.empty?
        IO.popen(Shellwords.split(pager), "w") { |io| io.write(text) }
      else
        $stdout.write(text)
      end
    end
  end
end
