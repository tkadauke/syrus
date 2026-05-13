# frozen_string_literal: true

require "open3"
require "rails_helper"

RSpec.describe "chat controller JavaScript" do
  it "passes the controller unit tests" do
    test_file = Rails.root.join("spec/javascript/chat_controller.test.mjs")
    stdout, stderr, status = Open3.capture3("node", "--test", test_file.to_s)

    expect(status).to be_success, [ stdout, stderr ].reject(&:blank?).join("\n")
  end
end
