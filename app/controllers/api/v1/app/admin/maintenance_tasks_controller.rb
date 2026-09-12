module Api
  module V1
    module App
      module Admin
        class MaintenanceTasksController < BaseController
          def index
            render json: ::App::MaintenanceTasksPayload.index(params: params)
          end

          def show
            render json: ::App::MaintenanceTasksPayload.show(task)
          end

          def start
            render json: ::App::MaintenanceTasksPayload.show(::MaintenanceTasks::Actions.start!(task, user: Current.user))
          end

          def pause
            render json: ::App::MaintenanceTasksPayload.show(::MaintenanceTasks::Actions.pause!(task, user: Current.user))
          end

          def resume
            render json: ::App::MaintenanceTasksPayload.show(::MaintenanceTasks::Actions.resume!(task, user: Current.user))
          end

          def cancel
            render json: ::App::MaintenanceTasksPayload.show(::MaintenanceTasks::Actions.cancel!(task, user: Current.user))
          end

          def dismiss
            render json: ::App::MaintenanceTasksPayload.show(::MaintenanceTasks::Actions.dismiss!(task, user: Current.user))
          end

          def discover
            MaintenanceTasks::Discovery.call
            render json: ::App::MaintenanceTasksPayload.index(params: params)
          end

          private

          def task
            @task ||= MaintenanceTask.find(params[:id])
          end
        end
      end
    end
  end
end
