module Repositories
  class ChatPendingActionsController < ApplicationController
    before_action :load_repository
    before_action :load_pending_action

    def confirm
      result = @pending_action.confirm!(user: Current.user)
      if result
        notice = result.respond_to?(:label) ? "Recurring task scheduled: #{result.label}." : "Pending action confirmed."
        redirect_to repository_chats_path(@repository), notice: notice
      else
        redirect_to repository_chats_path(@repository), alert: "Pending action is no longer active."
      end
    rescue ActiveRecord::RecordInvalid => e
      redirect_to repository_chats_path(@repository), alert: e.record.errors.full_messages.to_sentence.presence || "Pending action could not be confirmed."
    rescue ActiveRecord::RecordNotFound, ArgumentError => e
      redirect_to repository_chats_path(@repository), alert: e.message
    end

    def destroy
      result = if @pending_action.action_type == "schedule_recurring"
        @pending_action.cancel!(user: Current.user)
      else
        @pending_action.reject!
      end

      if result
        redirect_to repository_chats_path(@repository), notice: "Pending action cancelled."
      else
        redirect_to repository_chats_path(@repository), alert: "Pending action is no longer active."
      end
    rescue ActiveRecord::RecordNotFound => e
      redirect_to repository_chats_path(@repository), alert: e.message
    end

    private

    def load_repository
      @repository = Current.user.repositories.find(params[:repository_id])
    end

    def load_pending_action
      @pending_action = ChatPendingAction.where(repository: @repository, user: Current.user).find(params[:id])
    end
  end
end
