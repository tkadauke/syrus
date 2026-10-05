require "syrus/precompressed_asset_builder"

namespace :assets do
  desc "Precompress compiled public assets with Brotli when available and gzip"
  task precompress: :environment do
    written = Syrus::PrecompressedAssetBuilder.new(
      output_path: Rails.application.config.assets.output_path
    ).call
    puts "Precompressed #{written.size} asset variants"
  end
end

Rake::Task["assets:precompile"].enhance do
  Rake::Task["assets:precompress"].invoke
end
