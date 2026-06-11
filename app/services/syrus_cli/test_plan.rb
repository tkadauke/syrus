require "json"
require "net/http"
require "time"
require "uri"

module SyrusCli
  class TestPlan
    TERMINAL_STATES = %w[succeeded failed cancelled].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(slug:, base_url: nil, token: nil, stdout: $stdout, fetcher: nil)
      @slug = slug.to_s
      @base_url = base_url.presence || ENV["SYRUS_URL"].presence || ENV["SYRUS_APP_HOST"].presence
      @token = token.presence || ENV["SYRUS_API_TOKEN"].presence
      @stdout = stdout
      @fetcher = fetcher || method(:fetch_json)
    end

    def call
      job_id = parse_job_id
      response = @fetcher.call(job_uri(job_id), @token)
      payload = JSON.parse(response)
      plan = latest_completed_test_plan(payload)

      if plan
        print_plan(payload, plan)
      else
        @stdout.puts(
          %(No test plan available for #{normalized_slug(job_id)} yet — the job may still be implementing.)
        )
      end
    end

    private

    def parse_job_id
      match = @slug.match(/\AJOB-(\d+)\z/i)
      raise ArgumentError, "job must use JOB-<id> format" unless match

      match[1]
    end

    def job_uri(job_id)
      raise ArgumentError, "SYRUS_URL or SYRUS_APP_HOST is required" if @base_url.blank?
      raise ArgumentError, "SYRUS_API_TOKEN is required" if @token.blank?

      base = @base_url.to_s.strip.sub(%r{/\z}, "")
      base = "https://#{base}" unless base.match?(%r{\Ahttps?://}i)
      URI("#{base}/api/v1/admin/jobs/#{job_id}")
    end

    def fetch_json(uri, token)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{token}"
      request["Accept"] = "application/json"

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end

      raise "GET #{uri.path} failed with HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end

    def latest_completed_test_plan(payload)
      Array(payload["workflows"])
        .select { |workflow| TERMINAL_STATES.include?(workflow["state"].to_s) }
        .filter_map do |workflow|
          test_plan = workflow.dig("artifacts", "test_plan")
          next if test_plan.blank?

          [ workflow, test_plan ]
        end
        .max_by { |workflow, _test_plan| workflow_sort_key(workflow) }
        &.last
    end

    def workflow_sort_key(workflow)
      [
        parse_time(workflow["finished_at"]),
        parse_time(workflow["created_at"]),
        workflow["id"].to_i
      ]
    end

    def parse_time(value)
      Time.parse(value.to_s).to_f
    rescue ArgumentError
      0
    end

    def print_plan(payload, plan)
      @stdout.puts("Test plan for #{normalized_slug(payload.fetch("id"))}: #{payload["issue_title"]}")
      @stdout.puts
      Array(plan["steps"]).each.with_index(1) do |step, index|
        @stdout.puts("#{index}. #{step}")
      end

      notes = plan["notes"].to_s.strip
      return if notes.blank?

      @stdout.puts
      @stdout.puts("Notes: #{notes}")
    end

    def normalized_slug(job_id)
      "JOB-#{job_id}"
    end
  end
end
