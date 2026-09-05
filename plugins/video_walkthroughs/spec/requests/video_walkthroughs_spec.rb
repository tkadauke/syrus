require "rails_helper"

RSpec.describe "API: /api/v1/app video walkthroughs", type: :request do
  let(:user) { Factories.user(gemini_api_key: "gk-test") }
  let(:chat) { ChatSession.create!(user: user) }

  def parse_body
    JSON.parse(response.body)
  end

  def upload_file(name: "walkthrough.webm", content_type: "video/webm", content: "webm-bytes")
    file = Tempfile.new([ "walkthrough", File.extname(name) ])
    file.binmode
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, content_type, original_filename: name)
  end

  def create_walkthrough(chat:, state: "uploaded", **attrs)
    VideoWalkthroughs::Walkthrough.new({
      chat_session: chat,
      user: chat.user,
      content_type: "video/webm",
      byte_size: 10,
      duration_seconds: 60,
      state: state
    }.merge(attrs)).tap do |walkthrough|
      walkthrough.file.attach(io: StringIO.new("webm-bytes"), filename: "walkthrough.webm", content_type: "video/webm")
      walkthrough.save!
    end
  end

  # The plugin is its own feature flag now: it ships default_enabled false, so
  # every example that expects the endpoints to exist has to turn it on.
  before { PluginRecord.find_or_create_by!(name: "video_walkthroughs").update!(enabled: true, disableable: true) }

  before { ActiveJob::Base.queue_adapter.enqueued_jobs.clear }

  it "returns 404 for create and retry when the walkthrough feature is disabled" do
    sign_in_as(user)
    walkthrough = create_walkthrough(chat: chat, state: "failed")
    PluginRecord.find_by!(name: "video_walkthroughs").update!(enabled: false)

    post "/api/v1/app/chats/#{chat.id}/video_walkthroughs", params: { file: upload_file }
    expect(response).to have_http_status(:not_found)
    # The plugin route dispatcher answers this for every disabled plugin, so
    # the controller no longer carries a guard of its own.
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")

    post "/api/v1/app/video_walkthroughs/#{walkthrough.id}/retry"
    expect(response).to have_http_status(:not_found)
    # The plugin route dispatcher answers this for every disabled plugin, so
    # the controller no longer carries a guard of its own.
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
  end

  describe "POST /api/v1/app/chats/:chat_id/video_walkthroughs" do
    it "creates the walkthrough, persists the note on the row, and enqueues analysis with just the id" do
      sign_in_as(user)

      post "/api/v1/app/chats/#{chat.id}/video_walkthroughs", params: {
        file: upload_file,
        title: "Checkout run",
        duration_seconds: "95",
        note: "Watch the save button"
      }

      expect(response).to have_http_status(:created)
      walkthrough = VideoWalkthroughs::Walkthrough.last
      expect(walkthrough.chat_session).to eq(chat)
      expect(walkthrough.user).to eq(user)
      expect(walkthrough.state).to eq("uploaded")
      expect(walkthrough.byte_size).to eq("webm-bytes".bytesize)
      expect(walkthrough.content_type).to eq("video/webm")
      expect(walkthrough.duration_seconds).to eq(95)
      expect(walkthrough.title).to eq("Checkout run")
      expect(walkthrough.file).to be_attached
      # Regression: the note is PERSISTED on the row (not shipped as a
      # transient job kwarg) so a retry re-injects the user's guidance
      # instead of silently dropping it.
      expect(walkthrough.note).to eq("Watch the save button")

      expect(parse_body["video_walkthrough"]).to include(
        "id" => walkthrough.id,
        "chat_session_id" => chat.id,
        "state" => "uploaded",
        "title" => "Checkout run",
        "duration_seconds" => 95
      )

      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j[:job] == VideoWalkthroughs::AnalysisJob }
      expect(enqueued.size).to eq(1)
      # The job now takes only the id; the note comes from the persisted column.
      expect(enqueued.first[:args]).to eq([ walkthrough.id ])
    end

    it "422s with gemini_not_configured when the user has no Gemini key" do
      keyless = Factories.user
      keyless_chat = ChatSession.create!(user: keyless)
      sign_in_as(keyless)

      post "/api/v1/app/chats/#{keyless_chat.id}/video_walkthroughs", params: { file: upload_file }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("gemini_not_configured")
      expect(VideoWalkthroughs::Walkthrough.count).to eq(0)
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |j| j[:job] }).not_to include(VideoWalkthroughs::AnalysisJob)
    end

    it "422s with validation_failed for a non-video content type" do
      sign_in_as(user)

      post "/api/v1/app/chats/#{chat.id}/video_walkthroughs", params: {
        file: upload_file(name: "notes.txt", content_type: "text/plain", content: "not a video")
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
      expect(parse_body.dig("error", "message")).to include("webm")
      expect(VideoWalkthroughs::Walkthrough.count).to eq(0)
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |j| j[:job] }).not_to include(VideoWalkthroughs::AnalysisJob)
    end

    it "422s with missing_file when no file is attached" do
      sign_in_as(user)

      post "/api/v1/app/chats/#{chat.id}/video_walkthroughs", params: { title: "No video here" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("missing_file")
      expect(VideoWalkthroughs::Walkthrough.count).to eq(0)
    end

    it "404s for another user's chat" do
      other = Factories.user(gemini_api_key: "gk-other")
      sign_in_as(other)

      post "/api/v1/app/chats/#{chat.id}/video_walkthroughs", params: { file: upload_file }

      expect(response).to have_http_status(:not_found)
      expect(VideoWalkthroughs::Walkthrough.count).to eq(0)
    end
  end

  describe "POST /api/v1/app/video_walkthroughs/:id/retry" do
    it "resets a failed walkthrough to uploaded and re-enqueues analysis" do
      walkthrough = create_walkthrough(chat: chat, state: "failed", error_message: "quota busy")
      sign_in_as(user)

      post "/api/v1/app/video_walkthroughs/#{walkthrough.id}/retry"

      expect(response).to have_http_status(:ok)
      walkthrough.reload
      expect(walkthrough.state).to eq("uploaded")
      expect(walkthrough.error_message).to be_nil
      expect(parse_body["video_walkthrough"]).to include("id" => walkthrough.id, "state" => "uploaded")

      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j[:job] == VideoWalkthroughs::AnalysisJob }
      expect(enqueued.size).to eq(1)
      # Regression: retry re-enqueues with just the id (no user_note kwarg);
      # the note rides along on the persisted row.
      expect(enqueued.first[:args]).to eq([ walkthrough.id ])
    end

    it "422s with not_retryable for an analyzed walkthrough" do
      walkthrough = create_walkthrough(chat: chat, state: "analyzed", analyzed_at: Time.current)
      sign_in_as(user)

      post "/api/v1/app/video_walkthroughs/#{walkthrough.id}/retry"

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("not_retryable")
      expect(walkthrough.reload.state).to eq("analyzed")
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |j| j[:job] }).not_to include(VideoWalkthroughs::AnalysisJob)
    end

    it "404s for another user's walkthrough" do
      walkthrough = create_walkthrough(chat: chat, state: "failed", error_message: "boom")
      sign_in_as(Factories.user(gemini_api_key: "gk-other"))

      post "/api/v1/app/video_walkthroughs/#{walkthrough.id}/retry"

      expect(response).to have_http_status(:not_found)
      expect(walkthrough.reload.state).to eq("failed")
    end

    # The blob is the only thing enabling re-analysis; once the prune job
    # purges it AND there's no cached analysis, retry has nothing to work with.
    it "422s with video_expired when the analysis is blank and the blob is gone" do
      walkthrough = create_walkthrough(chat: chat, state: "failed", error_message: "quota busy")
      walkthrough.file.purge
      expect(walkthrough.reload.file).not_to be_attached
      expect(walkthrough.analysis).to be_blank
      sign_in_as(user)

      post "/api/v1/app/video_walkthroughs/#{walkthrough.id}/retry"

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("video_expired")
      expect(walkthrough.reload.state).to eq("failed")
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |j| j[:job] }).not_to include(VideoWalkthroughs::AnalysisJob)
    end

    # Re-delivery path: the earlier failure was in chat delivery, so the
    # analysis is already cached. Retry doesn't need the video and is allowed
    # even after the blob was pruned (the job skips Gemini and re-delivers).
    it "allows retry (200) when the analysis is present even though the blob is gone" do
      walkthrough = create_walkthrough(
        chat: chat, state: "failed", error_message: "posting failed",
        analysis: { "summary" => "cached", "issues" => [] }
      )
      walkthrough.file.purge
      expect(walkthrough.reload.file).not_to be_attached
      expect(walkthrough.analysis).to be_present
      sign_in_as(user)

      post "/api/v1/app/video_walkthroughs/#{walkthrough.id}/retry"

      expect(response).to have_http_status(:ok)
      walkthrough.reload
      expect(walkthrough.state).to eq("uploaded")
      expect(walkthrough.error_message).to be_nil
      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j[:job] == VideoWalkthroughs::AnalysisJob }
      expect(enqueued.size).to eq(1)
    end
  end

  describe "POST /api/v1/app/credentials/test_gemini_key" do
    it "returns an ok credential_test payload when the key lists a video-capable flash model" do
      fake_client = Class.new do
        def list_models
          [ "gemini-3.5-flash", "gemini-embedding-001" ]
        end
      end.new
      seen_api_keys = []
      original = VideoWalkthroughs::CredentialProbe.client_factory
      VideoWalkthroughs::CredentialProbe.client_factory = lambda do |api_key:|
        seen_api_keys << api_key
        fake_client
      end

      begin
        sign_in_as(user)

        post "/api/v1/app/credentials/test_gemini_key", params: { gemini_api_key: "gk-candidate" }

        expect(response).to have_http_status(:ok)
        body = parse_body
        expect(body["credential_test"]).to include(
          "credential" => "gemini_api_key",
          "ok" => true
        )
        expect(body["credential_test"]["message"]).to include("gemini-3.5-flash")
        expect(body["credential_test"]["details"]).to include("model" => "gemini-3.5-flash", "models_available" => 2)
        expect(body["message"]).to eq(body["credential_test"]["message"])
        expect(seen_api_keys).to eq([ "gk-candidate" ])
      ensure
        VideoWalkthroughs::CredentialProbe.client_factory = original
      end
    end
  end
end
