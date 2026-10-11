# frozen_string_literal: true

require "rails_helper"

RSpec.describe SpaAssetsHelper, type: :helper do
  def with_spa_entry_asset(name)
    path = Rails.root.join("app/assets/builds", name)
    FileUtils.mkdir_p(path.dirname)
    path.write("console.log('entry');")
    File.utime(Time.now + 10, Time.now + 10, path)
    yield
  ensure
    path&.delete if path&.exist?
  end

  it "emits the digested Vite entry without an asset revision query" do
    allow(SyrusVersion).to receive(:current).and_return("cache-sha")

    with_spa_entry_asset("spa-entry-helper123.digested.js") do
      tag = helper.spa_entry_javascript_include_tag(type: "module")

      expect(tag).to include('src="/assets/spa-entry-helper123.digested.js"')
      expect(tag).not_to include("?v=cache-sha")
    end
  end
end
