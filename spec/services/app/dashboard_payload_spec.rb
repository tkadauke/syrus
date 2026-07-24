require "rails_helper"

RSpec.describe App::DashboardPayload do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def call(params = {})
    described_class.call(user: user, params: ActionController::Parameters.new(params))
  end

  describe "default inbox view" do
    # Builtins are seeded by the service on each call, but we need them available
    # for assertions before the second call, so ensure them explicitly.
    before { SmartFolder.ensure_builtins_for_subject!("job") }

    let(:inbox_folder) { SmartFolder.find_builtin_by_attention("inbox") }

    it "reports the inbox SmartFolder's ID as active_smart_folder_id" do
      result = call(subject: "job", view: "list")
      expect(result[:active_smart_folder_id]).to eq(inbox_folder.id)
    end

    it "reads sort preferences from the inbox folder's slot (round-trip)" do
      # The frontend saves sort preferences keyed by active_smart_folder_id.
      # On the default inbox view that is inbox_folder.id, so we write there.
      user.update_dashboard_folder_preferences!(
        subject: "job",
        smart_folder_id: inbox_folder.id,
        sort_column: "started_at",
        sort_direction: "asc"
      )

      result = call(subject: "job", view: "list")

      # active_folder_key_for_prefs must resolve to inbox_folder.id so the
      # preference slot written above is actually read back here.
      expect(result[:preferences][:sort]).to include(column: "started_at", direction: "asc")
    end

    it "does not bleed inbox folder preferences into the key-null slot" do
      # Preferences saved under the inbox folder's numeric ID must not affect
      # reads keyed by "null" (explicit smart_folder_id=nil in the URL).
      user.update_dashboard_folder_preferences!(
        subject: "job",
        smart_folder_id: inbox_folder.id,
        sort_column: "started_at",
        sort_direction: "asc"
      )

      # An explicit smart_folder_id=nil in params means "no folder" — should
      # NOT see the inbox-keyed preference.
      result = call(subject: "job", view: "list", smart_folder_id: nil)

      default_column = User::DASHBOARD_SORT_DEFAULTS.fetch("job").fetch("column")
      expect(result[:preferences][:sort]).to include(column: default_column)
    end

    it "does not activate inbox default when a filter param is present" do
      result = call(subject: "job", view: "list", "q" => "state:running")
      # With a filter param, default_inbox_smart_folder? is false;
      # active_smart_folder should be nil (no inbox fallback).
      expect(result[:active_smart_folder_id]).to be_nil
    end
  end
end
