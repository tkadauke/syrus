require "rails_helper"

RSpec.describe JsonErrorRendering, type: :controller do
  controller(ActionController::Base) do
    include JsonErrorRendering

    def index
      render_error("invalid_widget", I18n.t("server.errors.invalid_request"), status: :unprocessable_content)
    end
  end

  it "returns a stable machine code beside the localized message" do
    I18n.with_locale(:de) { get :index }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq(
      "error" => { "code" => "invalid_widget", "message" => "Die Anfrage ist ungültig." }
    )
  end
end
