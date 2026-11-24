require "rails_helper"

RSpec.describe "App API achievements", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let!(:instance_unlock) { Achievements::Unlock.record!("example.first_epic_landed", subject: Factories.epic, evidence: { "secret" => "x" }).first }
  let!(:own_unlock) { Achievements::Unlock.record!("example.first_job_landed", user_id: user.id, subject: Factories.job).first }
  let!(:other_unlock) { Achievements::Unlock.record!("example.first_job_landed", user_id: other_user.id, subject: Factories.job).first }

  def body = JSON.parse(response.body)

  def set_enabled(value)
    PluginRecord.find_or_create_by!(name: "achievements").update!(enabled: value, disableable: true)
  end

  before { set_enabled(true) }

  describe "unauthenticated and disabled" do
    it "requires a session" do
      get "/api/v1/app/achievements"
      expect(response).to have_http_status(:unauthorized)
    end

    it "is not served while the plugin is disabled" do
      set_enabled(false)
      sign_in_as(user)

      get "/api/v1/app/achievements"

      expect(response).to have_http_status(:not_found)
      expect(Achievements::Unlock.count).to eq(3)
    end
  end

  describe "as a user" do
    before { sign_in_as(user) }

    it "lists only visible unlocks without evidence or subject references" do
      get "/api/v1/app/achievements"

      expect(response).to have_http_status(:ok)
      expect(body["achievements"].map { |row| row["id"] }).to contain_exactly(instance_unlock.id, own_unlock.id)
      expect(response.body).not_to include("secret")
      expect(body["achievements"].flat_map(&:keys)).not_to include("evidence", "subject_id", "user_id")
    end

    it "returns pending reveals and drops one once acknowledged" do
      get "/api/v1/app/achievements/pending"
      expect(body["achievements"].size).to eq(2)

      post "/api/v1/app/achievements/#{own_unlock.id}/acknowledge"
      expect(response).to have_http_status(:ok)
      expect(body.dig("achievement", "acknowledged")).to be(true)

      get "/api/v1/app/achievements/pending"
      expect(body["achievements"].map { |row| row["id"] }).to eq([ instance_unlock.id ])
    end

    it "lists locked definitions, reducing hidden ones to their scope" do
      get "/api/v1/app/achievements"

      locked = body["locked"]
      expect(locked).to include({ "hidden" => true, "scope" => "instance" })
      expect(locked.flat_map(&:keys)).not_to include("key") if locked.all? { |row| row["hidden"] }
      expect(response.body).not_to include("example.secret_milestone")
      expect(body["achievements"].map { |row| row["key"] }).not_to include("example.secret_milestone")
    end

    it "links evidence only to subjects the viewer can access" do
      accessible = Factories.job(repository: Factories.repository(user: user))
      Achievements::Unlock.where(id: own_unlock.id).update_all(subject_id: accessible.id)

      get "/api/v1/app/achievements"

      rows = body["achievements"].index_by { |row| row["id"] }
      expect(rows[own_unlock.id]["evidence_link"]).to eq("kind" => "job", "id" => accessible.id, "slug" => accessible.slug)
      expect(rows[instance_unlock.id]["evidence_link"]).to be_nil
      expect(response.body).not_to include(Epic.find(instance_unlock.subject_id).slug)
    end

    it "filters pending reveals to an accessible Job and yields nothing for an inaccessible one" do
      accessible = Factories.job(repository: Factories.repository(user: user))
      Achievements::Unlock.where(id: own_unlock.id).update_all(subject_id: accessible.id)

      get "/api/v1/app/achievements/pending", params: { subject_type: "job", subject_id: accessible.id }
      expect(body["achievements"].map { |row| row["id"] }).to eq([ own_unlock.id ])

      get "/api/v1/app/achievements/pending", params: { subject_type: "job", subject_id: other_unlock.subject_id }
      expect(body["achievements"]).to eq([])
    end

    it "hides other users' unlocks as not found" do
      post "/api/v1/app/achievements/#{other_unlock.id}/acknowledge"
      expect(response).to have_http_status(:not_found)

      post "/api/v1/app/achievements/#{other_unlock.id}/replay"
      expect(response).to have_http_status(:not_found)
      expect(Achievements::Acknowledgment.count).to eq(0)
    end

    it "replays a reveal and resets only the caller's acknowledgments" do
      Achievements::Reveals.new(user).acknowledge!(own_unlock.id)
      Achievements::Reveals.new(other_user).acknowledge!(other_unlock.id)

      post "/api/v1/app/achievements/#{own_unlock.id}/replay"
      expect(response).to have_http_status(:ok)
      expect(body.dig("achievement", "acknowledged")).to be(false)

      Achievements::Reveals.new(user).acknowledge!(instance_unlock.id)
      post "/api/v1/app/achievements/reset_acknowledgments"
      expect(body["reset"]).to eq(1)
      expect(Achievements::Acknowledgment.pluck(:user_id)).to eq([ other_user.id ])
    end

    it "forbids the admin reset for non-admins" do
      Achievements::Reveals.new(user).acknowledge!(own_unlock.id)

      post "/api/v1/app/admin/achievements/reset_acknowledgments", params: { confirm: Achievements::Reveals::CONFIRM_RESET_ALL }

      expect(response).to have_http_status(:forbidden)
      expect(Achievements::Acknowledgment.count).to eq(1)
    end
  end

  describe "as an admin" do
    before { sign_in_as(admin) }

    it "requires explicit confirmation before resetting everyone" do
      Achievements::Reveals.new(user).acknowledge!(own_unlock.id)

      post "/api/v1/app/admin/achievements/reset_acknowledgments"
      expect(response).to have_http_status(:unprocessable_content)
      expect(body.dig("error", "code")).to eq("confirmation_required")
      expect(Achievements::Acknowledgment.count).to eq(1)
    end

    it "resets all acknowledgments and leaves unlocks and timestamps untouched" do
      Achievements::Reveals.new(user).acknowledge!(own_unlock.id)
      Achievements::Reveals.new(other_user).acknowledge!(instance_unlock.id)
      snapshot = Achievements::Unlock.order(:id).map(&:attributes)

      post "/api/v1/app/admin/achievements/reset_acknowledgments", params: { confirm: Achievements::Reveals::CONFIRM_RESET_ALL }

      expect(response).to have_http_status(:ok)
      expect(body["reset"]).to eq(2)
      expect(Achievements::Acknowledgment.count).to eq(0)
      expect(Achievements::Unlock.order(:id).map(&:attributes)).to eq(snapshot)
    end
  end
end
