require "rails_helper"

RSpec.describe "Cron templates", type: :request do
  let(:user)       { Factories.user }
  let(:other_user) { Factories.user }

  let(:valid_attrs) do
    {
      name: "Weekly dependency bump",
      prompt: "Bump outdated gems.",
      cron_expression: "0 9 * * 1",
      pr_pileup_policy: "skip",
      enabled: true
    }
  end

  it "requires authentication on index" do
    get cron_templates_path
    expect(response).to redirect_to(new_session_path).or redirect_to(new_user_path)
  end

  context "signed in" do
    before { sign_in_as(user) }

    describe "GET /cron_templates" do
      it "lists the user's templates" do
        user.cron_templates.create!(valid_attrs)
        get cron_templates_path
        expect(response).to be_successful
        expect(response.body).to include("Weekly dependency bump")
      end

      it "doesn't show another user's templates" do
        other_user.cron_templates.create!(valid_attrs.merge(name: "Their template"))
        get cron_templates_path
        expect(response.body).not_to include("Their template")
      end
    end

    describe "GET /cron_templates/new" do
      it "renders the form" do
        get new_cron_template_path
        expect(response).to be_successful
        expect(response.body).to include("New cron template")
      end
    end

    describe "POST /cron_templates" do
      it "creates a template and redirects to show" do
        expect {
          post cron_templates_path, params: { cron_template: valid_attrs }
        }.to change { user.cron_templates.count }.by(1)
        tmpl = CronTemplate.last
        expect(response).to redirect_to(cron_template_path(tmpl))
        expect(tmpl.name).to eq("Weekly dependency bump")
        expect(tmpl.user).to eq(user)
      end

      it "rejects an invalid cron expression" do
        post cron_templates_path,
             params: { cron_template: valid_attrs.merge(cron_expression: "*/5 * * * *") }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("at most once per hour")
      end

      it "rejects a missing name" do
        post cron_templates_path,
             params: { cron_template: valid_attrs.merge(name: "") }
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    describe "GET /cron_templates/:id" do
      let(:template) { user.cron_templates.create!(valid_attrs) }

      it "shows the template" do
        get cron_template_path(template)
        expect(response).to be_successful
        expect(response.body).to include("Weekly dependency bump")
      end

      it "refuses to show another user's template" do
        other_tmpl = other_user.cron_templates.create!(valid_attrs.merge(name: "Theirs"))
        get cron_template_path(other_tmpl)
        expect(response).to have_http_status(:not_found)
      end
    end

    describe "PATCH /cron_templates/:id" do
      it "updates the template" do
        template = user.cron_templates.create!(valid_attrs)
        patch cron_template_path(template),
              params: { cron_template: { prompt: "Updated prompt." } }
        expect(response).to redirect_to(cron_template_path(template))
        expect(template.reload.prompt).to eq("Updated prompt.")
      end

      it "rejects updates from other users" do
        other_tmpl = other_user.cron_templates.create!(valid_attrs)
        patch cron_template_path(other_tmpl),
              params: { cron_template: { prompt: "hijack" } }
        expect(response).to have_http_status(:not_found)
      end
    end

    describe "DELETE /cron_templates/:id" do
      it "destroys the template" do
        template = user.cron_templates.create!(valid_attrs)
        expect {
          delete cron_template_path(template)
        }.to change { CronTemplate.count }.by(-1)
        expect(response).to redirect_to(cron_templates_path)
      end

      it "refuses to delete another user's template" do
        other_tmpl = other_user.cron_templates.create!(valid_attrs)
        expect {
          delete cron_template_path(other_tmpl)
        }.not_to change { CronTemplate.count }
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
