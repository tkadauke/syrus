# SimpleCov must be started before any application code is required so that
# it can instrument every file from the first load. COVERAGE=false skips it.
if ENV['COVERAGE'] != 'false'
  # Bootsnap's ISEq compile cache calls RubyVM::InstructionSequence#to_binary,
  # which raises "should not compile with coverage" when Coverage is active.
  # Disable the cache before Bootsnap is loaded (config/boot.rb) so the two
  # can coexist. DISABLE_BOOTSNAP_COMPILE_CACHE is checked in Bootsnap.default_setup.
  ENV['DISABLE_BOOTSNAP_COMPILE_CACHE'] = '1'

  require 'simplecov'
  require 'simplecov-lcov'

  SimpleCov::Formatter::LcovFormatter.config do |c|
    c.report_with_single_file = true
    c.single_report_path = 'coverage/lcov.info'
  end
  SimpleCov.formatter = SimpleCov::Formatter::LcovFormatter
  SimpleCov.start 'rails' do
    add_filter '/spec/'
    add_filter '/config/'
    add_filter '/db/'
    add_filter '/bin/'
    enable_coverage :branch
  end
end

# This file is copied to spec/ when you run 'rails generate rspec:install'
require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
# Prevent database truncation if the environment is production
abort("The Rails environment is running in production mode!") if Rails.env.production?
# Uncomment the line below in case you have `--require rails_helper` in the `.rspec` file
# that will avoid rails generators crashing because migrations haven't been run yet
# return unless Rails.env.test?
require 'rspec/rails'
# Add additional requires below this line. Rails is not loaded until this point!

# Requires supporting ruby files with custom matchers and macros, etc, in
# spec/support/ and its subdirectories. Files matching `spec/**/*_spec.rb` are
# run as spec files by default. This means that files in spec/support that end
# in _spec.rb will both be required and run as specs, causing the specs to be
# run twice. It is recommended that you do not name files matching this glob to
# end with _spec.rb. You can configure this pattern with the --pattern
# option on the command line or in ~/.rspec, .rspec or `.rspec-local`.
#
# The following line is provided for convenience purposes. It has the downside
# of increasing the boot-up time by auto-requiring all files in the support
# directory. Alternatively, in the individual `*_spec.rb` files, manually
# require only the support files necessary.
#
Rails.root.glob('spec/support/**/*.rb').sort_by(&:to_s).each { |f| require f }

# Ensures that the test database schema matches the current schema file.
# If there are pending migrations it will invoke `db:test:prepare` to
# recreate the test database by loading the schema.
# If you are not using ActiveRecord, you can remove these lines.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end
RSpec.configure do |config|
  # Run each example inside a transaction.
  config.use_transactional_fixtures = true

  config.include ActiveSupport::Testing::TimeHelpers

  # Never actually sleep while waiting for GitHub mergeability to
  # settle in the auto_merge step (see Steps::AutoMerge).
  config.before do
    Current.reset
    Steps::AutoMerge.mergeability_settle_delay = 0
    # Stub the GitHub API call made by RepoAdversarialReviewPlan#resolve so
    # that specs using Factories.job (which instantiates an Initial workflow)
    # don't silently rely on rescue StandardError catching a WebMock error.
    # Specs that need adversarial review enabled override this in a local before.
    allow(RepoAdversarialReviewPlan).to receive(:for_job)
      .and_return(RepoAdversarialReviewPlan::Result.new(rounds: 0, source: "none", note: "no .syrus.yml", criteria: []))
  end

  config.after do
    Current.reset
  end

  # You can uncomment this line to turn off ActiveRecord support entirely.
  # config.use_active_record = false

  # RSpec Rails uses metadata to mix in different behaviours to your tests,
  # for example enabling you to call `get` and `post` in request specs. e.g.:
  #
  #     RSpec.describe UsersController, type: :request do
  #       # ...
  #     end
  #
  # The different available types are documented in the features, such as in
  # https://rspec.info/features/8-0/rspec-rails
  #
  # You can also infer these behaviours automatically by location, e.g.
  # /spec/models would pull in the same behaviour as `type: :model` but this
  # behaviour is considered legacy and will be removed in a future version.
  #
  # To enable this behaviour uncomment the line below.
  # config.infer_spec_type_from_file_location!

  # Filter lines from Rails gems in backtraces.
  config.filter_rails_from_backtrace!
  # arbitrary gems may also be filtered via:
  # config.filter_gems_from_backtrace("gem name")
end
