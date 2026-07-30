module Api
  module V1
    module App
      class JobTestResultsController < BaseController
        def index
          job = find_job

          latest_workflow = job.workflows
            .joins(steps: :runs)
            .joins("INNER JOIN test_runs ON test_runs.run_id = runs.id")
            .order(created_at: :desc)
            .first

          unless latest_workflow
            render json: { job_id: job.id, workflow_id: nil, test_runs: [] }
            return
          end

          test_runs = TestRun.joins(run: { step: :workflow })
            .where(workflows: { id: latest_workflow.id })
            .includes(:test_cases)
            .order(:grader_name)

          render json: {
            job_id: job.id,
            workflow_id: latest_workflow.id,
            test_runs: test_runs.map { |tr| test_run_json(tr) }
          }
        end

        private

        def find_job
          scope = Current.user.jobs
          find_job_by_ref(scope, params[:job_id])
        end

        def test_run_json(test_run)
          suites = test_run.test_cases.group_by(&:suite_name).map do |suite_name, cases|
            {
              suite_name: suite_name,
              total_count: cases.size,
              passed_count: cases.count { |tc| tc.status == "passed" },
              failed_count: cases.count { |tc| tc.status == "failed" },
              skipped_count: cases.count { |tc| tc.status == "skipped" },
              error_count: cases.count { |tc| tc.status == "error" },
              test_cases: cases.map { |tc| test_case_json(tc) }
            }
          end

          {
            id: test_run.id,
            grader_name: test_run.grader_name,
            run_id: test_run.run_id,
            total_count: test_run.total_count,
            passed_count: test_run.passed_count,
            failed_count: test_run.failed_count,
            skipped_count: test_run.skipped_count,
            error_count: test_run.error_count,
            duration_ms: test_run.duration_ms,
            suites: suites
          }
        end

        def test_case_json(test_case)
          {
            id: test_case.id,
            name: test_case.name,
            suite_name: test_case.suite_name,
            file_path: test_case.file_path,
            status: test_case.status,
            duration_ms: test_case.duration_ms,
            failure_message: test_case.failure_message,
            failure_backtrace: test_case.failure_backtrace,
            output: test_case.output
          }
        end
      end
    end
  end
end
