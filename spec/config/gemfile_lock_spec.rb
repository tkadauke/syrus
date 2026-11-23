# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Gemfile.lock" do
  let(:lockfile) { File.read(File.expand_path("../../Gemfile.lock", __dir__)) }

  # Regression: the precompiled darwin builds of bcrypt_pbkdf only support
  # Ruby < 3.4. With them locked, a frozen bundle install on an arm64 Mac
  # worker failed instead of building the source gem.
  it "locks only the source build of bcrypt_pbkdf" do
    variants = lockfile.scan(/^    bcrypt_pbkdf \(([^)]+)\)$/).flatten

    expect(variants).not_to be_empty
    expect(variants).to all(match(/\A[\d.]+\z/)), "platform-specific bcrypt_pbkdf locked: #{variants.inspect}"
  end
end
