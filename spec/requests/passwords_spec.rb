require "rails_helper"

RSpec.describe "Password resets", type: :request do
  it "rejects a blank password without destroying sessions or consuming the reset token" do
    user = Factories.user(password: "oldsecret")
    session = user.sessions.create!
    token = user.password_reset_token

    patch password_path(token), params: { password: "", password_confirmation: "" }

    expect(response).to redirect_to(edit_password_path(token))
    expect(user.sessions.reload).to contain_exactly(session)
    expect(User.authenticate_by(email_address: user.email_address, password: "oldsecret")).to eq(user)
    expect(User.find_by_password_reset_token!(token)).to eq(user)
  end
end
