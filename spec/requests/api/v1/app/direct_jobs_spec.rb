require "rails_helper"

RSpec.describe "API: /api/v1/app/direct_jobs", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  around do |example|
    old_runner = RunJob.agent_runner
    RunJob.agent_runner = nil
    example.run
  ensure
    RunJob.agent_runner = old_runner
  end

  def parse_body
    JSON.parse(response.body)
  end

  def upload_file(name: "notes.md", content_type: "text/markdown", content: "# Notes")
    file = Tempfile.new([ "direct-job", File.extname(name) ])
    file.binmode
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, content_type, original_filename: name)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/jobs/new"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "accepts a bearer API token for app API requests" do
    token = user.generate_api_token!
    repository

    get "/api/v1/app/jobs/new", headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["repositories"]).to include(include("slug" => "acme/widgets"))
  end

  it "creates direct jobs with a bearer API token" do
    token = user.generate_api_token!

    expect {
      post "/api/v1/app/jobs",
           params: {
             repository_id: repository.id,
             title: "Summon the build consul",
             prompt: "Make the tiny CLI action work.",
             priority: "medium"
           },
           headers: { "Authorization" => "Bearer #{token}" }
    }.to change(Job, :count).by(1)
      .and have_enqueued_job(RunJob)

    expect(response).to have_http_status(:created)
    expect(parse_body.dig("job", "title")).to eq("Summon the build consul")
  end

  it "returns the direct job form options for the signed-in user" do
    sign_in_as(user)
    user.update!(claude_oauth_token: "oat-test", codex_auth_mode: "api_key", codex_api_key: "sk-test")
    repository.update!(agent_provider: "codex")
    archived = Factories.repository(user: user, owner: "acme", name: "archive")
    archived.archive!
    Factories.repository(user: Factories.user, owner: "other", name: "private")

    get "/api/v1/app/jobs/new", params: { repository_id: repository.id, create_more: "1" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["repositories"]).to contain_exactly(
      include(
        "id" => repository.id,
        "slug" => "acme/widgets",
        "default_agent_provider" => "codex",
        "default_agent_provider_label" => "Codex"
      )
    )
    expect(body["configured_agent_providers"]).to contain_exactly(
      include("value" => "claude", "label" => "Claude Code"),
      include("value" => "codex", "label" => "Codex")
    )
    expect(body["selected_repository_id"]).to eq(repository.id.to_s)
    expect(body["create_more"]).to eq(true)
    expect(body["prompt_templates"]).to include(include("id" => "configure-syrus-prep", "prompt" => include("syrus")))
    expect(body["priorities"].map { |priority| priority["value"] }).to eq(%w[high medium low])
    expect(body["accepted_file_content_types"]).to include("application/pdf")
  end

  it "creates a direct job, starts the workflow, and returns its redirect" do
    sign_in_as(user)
    RunJob.agent_runner = ->(**_) { raise "explicit direct job titles should not invoke the title agent" }

    expect {
      post "/api/v1/app/jobs", params: {
        repository_id: repository.id,
        title: "Bump Ruby version",
        prompt: "Update the Ruby version in .ruby-version to 3.3.0.",
        priority: "high"
      }
    }.to change(Job, :count).by(1)
      .and have_enqueued_job(RunJob)

    expect(response).to have_http_status(:created)
    new_job = Job.order(:created_at).last
    expect(new_job.kind).to eq("direct")
    expect(new_job.issue_title).to eq("Bump Ruby version")
    expect(new_job).not_to be_title_pending
    expect(new_job.issue_body).to eq("Update the Ruby version in .ruby-version to 3.3.0.")
    expect(new_job.priority).to eq("high")
    expect(new_job.issue_number).to be_nil
    expect(new_job.repository).to eq(repository)
    expect(new_job.runs.count).to eq(1)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |entry| entry[:job] }).not_to include(GenerateJobTitleJob)
    expect(new_job.runs.first.trigger_kind).to eq("initial")
    expect(new_job.runs.first.prompt).to include("Update the Ruby version")
    expect(parse_body).to include(
      "message" => "Direct job created.",
      "create_more" => false,
      "redirect_to" => job_path(new_job)
    )
    expect(parse_body.dig("job", "title")).to eq("Bump Ruby version")
    expect(parse_body.dig("job", "title_pending")).to eq(false)
  end

  it "marks the title pending and enqueues title generation when the title is blank" do
    sign_in_as(user)
    RunJob.agent_runner = ->(**_) { raise "blank direct job titles should not invoke the title agent inline" }

    expect {
      post "/api/v1/app/jobs", params: {
        repository_id: repository.id,
        title: " ",
        prompt: "- `Tighten the dashboard filters`\n\nUse native validity for the form."
      }
    }.to have_enqueued_job(GenerateJobTitleJob)

    expect(response).to have_http_status(:created)
    new_job = Job.order(:created_at).last
    expect(new_job.issue_title).to eq("Generating title...")
    expect(new_job).to be_title_pending
    expect(parse_body.dig("job", "title")).to eq("Generating title...")
    expect(parse_body.dig("job", "title_pending")).to eq(true)
  end

  it "uses an explicitly selected configured agent for the job, workflow, and run" do
    sign_in_as(user)
    user.update!(claude_oauth_token: "oat-test", codex_auth_mode: "api_key", codex_api_key: "sk-test")
    repository.update!(agent_provider: "claude")

    post "/api/v1/app/jobs", params: {
      repository_id: repository.id,
      agent_provider: "codex",
      prompt: "Do something."
    }

    new_job = Job.order(:created_at).last
    expect(new_job.agent_provider).to eq("codex")
    expect(new_job.workflows.order(:created_at).last.agent_provider).to eq("codex")
    expect(new_job.runs.first.agent_provider).to eq("codex")
  end

  it "defaults direct jobs to the repository's effective agent" do
    sign_in_as(user)
    user.update!(agent_provider: "claude", claude_oauth_token: "oat-test",
                 codex_auth_mode: "api_key", codex_api_key: "sk-test")
    repository.update!(agent_provider: "codex")

    post "/api/v1/app/jobs", params: {
      repository_id: repository.id,
      prompt: "Do something."
    }

    new_job = Job.order(:created_at).last
    expect(new_job.agent_provider).to eq("codex")
    expect(new_job.workflows.order(:created_at).last.agent_provider).to eq("codex")
    expect(new_job.runs.first.agent_provider).to eq("codex")
  end

  it "keeps the operator on the new form when Create More is checked" do
    sign_in_as(user)

    post "/api/v1/app/jobs", params: {
      repository_id: repository.id,
      prompt: "Do something.",
      create_more: "1"
    }

    expect(response).to have_http_status(:created)
    expect(parse_body).to include(
      "create_more" => true,
      "redirect_to" => new_job_path(repository_id: repository.id, create_more: "1")
    )
  end

  it "creates file and Google Doc attachments for the new job" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/jobs", params: {
        repository_id: repository.id,
        prompt: "Read the context and update the app.",
        job_attachment: {
          files: [ upload_file ],
          google_doc_url: "https://docs.google.com/document/d/context/edit"
        }
      }
    }.to change(Document, :count).by(2)

    new_job = Job.order(:created_at).last
    attachments = new_job.job_attachments.includes(file_attachment: :blob)
    expect(attachments.map(&:kind)).to contain_exactly("file", "google_doc")
    expect(attachments.detect(&:file?)&.filename).to eq("notes.md")
    expect(attachments.detect(&:google_doc?)&.google_doc_url).to eq("https://docs.google.com/document/d/context/edit")
  end

  it "parses dependencies from the direct prompt and waits to dispatch" do
    sign_in_as(user)
    prerequisite = Job.create!(user: user, repository: repository, issue_number: 41)

    expect {
      post "/api/v1/app/jobs", params: {
        repository_id: repository.id,
        prompt: "Do something useful.\nDepends-on: #41"
      }
    }.to change(Job, :count).by(1)

    new_job = Job.order(:created_at).last
    expect(response).to have_http_status(:created)
    expect(new_job.dependencies.first.depends_on_job).to eq(prerequisite)
    expect(new_job.runs).to be_empty
  end

  it "rejects invalid attachments and destroys the draft job" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/jobs", params: {
        repository_id: repository.id,
        prompt: "Use this file.",
        job_attachment: {
          files: [ upload_file(name: "archive.zip", content_type: "application/zip", content: "zip") ]
        }
      }
    }.not_to change(Job, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(parse_body.dig("error", "message")).to include("supported text, PDF, Office, or image file")
  end

  it "rejects blank prompts, missing repositories, and unconfigured agents" do
    sign_in_as(user)
    user.update!(claude_oauth_token: "oat-test")

    aggregate_failures do
      expect {
        post "/api/v1/app/jobs", params: { repository_id: repository.id, prompt: "  " }
      }.not_to change(Job, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to include("blank")

      expect {
        post "/api/v1/app/jobs", params: { repository_id: "", prompt: "Do something." }
      }.not_to change(Job, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to include("Repository not found")

      expect {
        post "/api/v1/app/jobs", params: { repository_id: repository.id, agent_provider: "codex", prompt: "Do something." }
      }.not_to change(Job, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to include("not configured")
    end
  end

  it "does not create a direct job for another user's repository" do
    sign_in_as(user)
    foreign_repo = Factories.repository(user: Factories.user)

    expect {
      post "/api/v1/app/jobs", params: {
        repository_id: foreign_repo.id,
        prompt: "Do something."
      }
    }.not_to change(Job, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("Repository not found")
  end
end
