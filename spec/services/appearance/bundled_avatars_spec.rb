require "rails_helper"

RSpec.describe "bundled avatars" do
  it "registers unique keys backed by shipped SVG files" do
    avatars = JSON.parse(Rails.root.join("config/appearance/avatars.json").read)

    expect(avatars.size).to eq(6)
    expect(avatars.map { |avatar| avatar.fetch("key") }.uniq.size).to eq(avatars.size)
    avatars.each do |avatar|
      expect(avatar.fetch("url")).to start_with("/bundled-avatars/")
      expect(Rails.root.join("public", avatar.fetch("url").delete_prefix("/"))).to exist
    end
    expect(Dir[Rails.root.join("public/bundled-avatars/*.svg")].map { |path| "/bundled-avatars/#{File.basename(path)}" }.sort).to eq(
      avatars.map { |avatar| avatar.fetch("url") }.sort
    )
  end
end
