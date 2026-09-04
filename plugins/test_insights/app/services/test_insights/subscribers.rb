module TestInsights
  # Ingests test results from grader output.
  #
  # This used to be Steps::Grader calling JunitXmlParser and TestRunIngester
  # directly. Core now publishes step.grader.completed with the output path and
  # nothing else -- it no longer knows what a test case is. Delivery is inline
  # because the path points inside the workflow workspace, which is torn down
  # when the workflow reaches a terminal state.
  class Subscribers
    include Syrus::Plugin::DomainSubscriber

    def self.subscriptions
      { "step.grader.completed" => :on_grader_completed }
    end

    def self.on_grader_completed(event)
      output_path = event[:junit_output_path].presence
      return if output_path.blank?

      path = Pathname.new(output_path)
      return unless path.file?

      run = Run.find_by(id: event[:run_id])
      return if run.nil?

      parser_name = nil
      parser_name, parsed = parse(path, event[:format_hint])
      return if parsed.nil?

      Ingester.new(run: run, grader_name: event[:grader_name].to_s, parsed_run: parsed).ingest!
      log(run, "[grader:#{event[:grader_name]}] ingested #{parsed.total_count} test case(s) from #{path.basename}")
    rescue ::JunitXmlParser::ParseError => e
      # Logged to the run rather than only to Rails.logger: an operator looking
      # for why a grader produced no test data looks at the grader log.
      log(run, "[grader:#{event[:grader_name]}] warning: JunitXmlParser: JUnit XML parse error: #{e.message}")
    rescue StandardError => e
      # Names the parser: when a plugin's parser breaks the ParsedRun contract,
      # which plugin it was is the whole diagnostic.
      log(run, "[grader:#{event[:grader_name]}] warning: test output ingestion failed via #{parser_name || 'JunitXmlParser'}: #{e.class}: #{e.message}")
    end

    def self.log(run, message)
      return if run.nil?

      JobLog.append!(run: run, chunk: message, kind: nil)
    rescue StandardError => e
      Rails.logger.warn("[TestInsights] could not write job log: #{e.class}: #{e.message}")
    end

    # Language plugins contribute framework-native parsers through
    # "test_insights:parser"; JUnit XML is the fallback every language can emit.
    def self.parse(path, format_hint)
      Syrus::PluginRegistry.providers_for("test_insights:parser").each do |provider|
        can_parse = PerformanceLogging.plugin_call(extension_point: "test_insights:parser", provider: provider, operation: :can_parse) do
          provider.can_parse?(output_path: path, format_hint: format_hint)
        end
        next unless can_parse

        parsed = PerformanceLogging.plugin_call(extension_point: "test_insights:parser", provider: provider, operation: :call) do
          provider.call(output_path: path, format_hint: format_hint)
        end
        return [ provider.to_s, parsed ]
      end

      [ "JunitXmlParser", ::JunitXmlParser.parse(path.read) ]
    end
  end
end
