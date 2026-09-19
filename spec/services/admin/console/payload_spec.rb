require "rails_helper"

RSpec.describe Admin::Console::Payload do
  let!(:admin) { Factories.user }
  let(:non_admin) { Factories.user }
  let(:payload) { described_class.new(actor: non_admin) }

  describe "privileged mutations" do
    before do
      AppSetting.current.update!(
        polling_paused: false,
        runs_paused: false,
        merge_train_enabled: false
      )
    end

    it "rejects pause setting updates from a non-admin actor" do
      expect {
        payload.pause_polling(source: "spec")
      }.to raise_error(ArgumentError, "Admin access required.")

      expect {
        payload.pause_runs(source: "spec")
      }.to raise_error(ArgumentError, "Admin access required.")

      expect {
        payload.enable_merge_train(source: "spec")
      }.to raise_error(ArgumentError, "Admin access required.")

      settings = AppSetting.current.reload
      expect(settings.polling_paused).to be(false)
      expect(settings.runs_paused).to be(false)
      expect(settings.merge_train_enabled).to be(false)
      expect(AdminAction.count).to eq(0)
    end

    it "rejects pause setting resets from a non-admin actor" do
      AppSetting.current.update!(
        polling_paused: true,
        runs_paused: true,
        merge_train_enabled: true
      )

      expect {
        payload.unpause_polling(source: "spec")
      }.to raise_error(ArgumentError, "Admin access required.")

      expect {
        payload.unpause_runs(source: "spec")
      }.to raise_error(ArgumentError, "Admin access required.")

      expect {
        payload.disable_merge_train(source: "spec")
      }.to raise_error(ArgumentError, "Admin access required.")

      settings = AppSetting.current.reload
      expect(settings.polling_paused).to be(true)
      expect(settings.runs_paused).to be(true)
      expect(settings.merge_train_enabled).to be(true)
      expect(AdminAction.count).to eq(0)
    end

    it "rejects GitHub cache clearing from a non-admin actor" do
      expect(Rails.cache).not_to receive(:delete_matched)

      expect {
        payload.clear_github_cache(user_id: admin.id, source: "spec")
      }.to raise_error(ArgumentError, "Admin access required.")

      expect(AdminAction.count).to eq(0)
    end
  end
end
