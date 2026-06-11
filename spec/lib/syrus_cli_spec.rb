require "spec_helper"
require "stringio"
require_relative "../../lib/syrus_cli"

RSpec.describe SyrusCli::CLI do
  class FakeSyrusHttp
    attr_reader :json_requests, :raw_requests

    def initialize(routes)
      @routes = routes
      @json_requests = []
      @raw_requests = []
    end

    def get_json(uri, token:)
      @json_requests << [ uri, token ]
      key = [ uri.path, URI.decode_www_form(uri.query.to_s).to_h ]
      @routes.fetch(key) { @routes.fetch([ uri.path, {} ]) }
    end

    def get_raw(uri, headers:)
      @raw_requests << [ uri, headers ]
      "diff --git a/README.md b/README.md\n"
    end
  end

  class FakePager
    attr_reader :writes

    def initialize
      @writes = []
    end

    def write(text)
      @writes << text
    end
  end

  class FakeRepoDetector
    def initialize(slug)
      @slug = slug
    end

    def slug = @slug
  end

  around do |example|
    old_instance = ENV["SYRUS_INSTANCE_URL"]
    old_token = ENV["SYRUS_API_TOKEN"]
    old_github = ENV["SYRUS_GITHUB_TOKEN"]
    ENV["SYRUS_INSTANCE_URL"] = "https://syrus.example.test"
    ENV["SYRUS_API_TOKEN"] = "syrus_secret1234"
    ENV.delete("SYRUS_GITHUB_TOKEN")
    example.run
  ensure
    ENV["SYRUS_INSTANCE_URL"] = old_instance
    ENV["SYRUS_API_TOKEN"] = old_token
    old_github.nil? ? ENV.delete("SYRUS_GITHUB_TOKEN") : ENV["SYRUS_GITHUB_TOKEN"] = old_github
  end

  def cli(routes, repo: "acme/widgets", pager: FakePager.new)
    out = StringIO.new
    err = StringIO.new
    http = FakeSyrusHttp.new(routes)
    instance = described_class.new(
      out: out,
      err: err,
      http_client: http,
      pager: pager,
      repo_detector: FakeRepoDetector.new(repo),
      sleep_proc: ->(_seconds) {}
    )
    [ instance, out, err, http, pager ]
  end

  it "lists jobs scoped to the current repository" do
    routes = {
      [ "/api/v1/admin/jobs", { "state" => "open", "repo" => "acme/widgets" } ] => {
        "jobs" => [
          { "id" => 456, "state" => "running", "repository" => "acme/widgets", "issue_title" => "Add dark mode", "pr_number" => 12 }
        ]
      }
    }
    instance, out, _err, http = cli(routes)

    expect(instance.run(%w[job list])).to eq(0)

    expect(out.string).to include("ID", "STATE", "REPO", "TITLE", "PR")
    expect(out.string).to include("456", "running", "acme/widgets", "Add dark mode", "PR #12")
    expect(http.json_requests.first.last).to eq("syrus_secret1234")
  end

  it "shows a job with current step and last transcript lines" do
    routes = {
      [ "/api/v1/admin/jobs/456", {} ] => {
        "id" => 456,
        "state" => "running",
        "issue_title" => "Add dark mode",
        "repository" => { "slug" => "acme/widgets" },
        "pr_number" => 12,
        "created_at" => "2026-06-11T12:00:00Z",
        "updated_at" => "2026-06-11T12:03:00Z",
        "workflows" => [
          {
            "created_at" => "2026-06-11T12:00:00Z",
            "steps" => [
              { "kind" => "prepare", "state" => "succeeded", "created_at" => "2026-06-11T12:00:00Z", "finished_at" => "2026-06-11T12:00:12Z", "runs" => [] },
              { "kind" => "implement", "state" => "running", "created_at" => "2026-06-11T12:01:00Z", "started_at" => "2026-06-11T12:01:00Z", "runs" => [
                { "id" => 99, "state" => "running", "created_at" => "2026-06-11T12:01:00Z" }
              ] }
            ]
          }
        ]
      },
      [ "/api/v1/admin/runs/99/transcript", { "per" => "500" } ] => {
        "pagination" => { "total_pages" => 1 },
        "events" => [
          { "data" => { "text" => "first" } },
          { "data" => { "text" => "last" } }
        ]
      }
    }
    instance, out = cli(routes)

    instance.run(%w[job show 456])

    expect(out.string).to include("Job #456: Add dark mode")
    expect(out.string).to include("Current step: implement running")
    expect(out.string).to include("first", "last")
  end

  it "prints the PR URL for diff when no GitHub token is configured" do
    routes = {
      [ "/api/v1/admin/jobs/456", {} ] => {
        "id" => 456,
        "repository" => { "slug" => "acme/widgets" },
        "pr_number" => 12
      }
    }
    instance, out = cli(routes)

    instance.run(%w[job diff 456])

    expect(out.string).to eq("https://github.com/acme/widgets/pull/12\n")
  end

  it "fetches the GitHub diff when a GitHub token is configured" do
    ENV["SYRUS_GITHUB_TOKEN"] = "ghp_diff"
    routes = {
      [ "/api/v1/admin/jobs/456", {} ] => {
        "id" => 456,
        "repository" => { "slug" => "acme/widgets" },
        "pr_number" => 12
      }
    }
    pager = FakePager.new
    instance, _out, _err, http = cli(routes, pager: pager)

    instance.run(%w[job diff 456])

    expect(http.raw_requests.first.first.to_s).to eq("https://api.github.com/repos/acme/widgets/pulls/12")
    expect(http.raw_requests.first.last).to include("Accept" => "application/vnd.github.diff")
    expect(pager.writes.first).to include("diff --git")
  end

  it "prints whoami using local token suffix" do
    routes = {
      [ "/api/v1/admin/whoami", {} ] => {
        "user" => { "email_address" => "admin@example.com" }
      }
    }
    instance, out = cli(routes)

    instance.run(%w[whoami])

    expect(out.string).to include("Email: admin@example.com")
    expect(out.string).to include("Instance: https://syrus.example.test")
    expect(out.string).to include("Token: ...1234")
  end
end
