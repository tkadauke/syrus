module Repositories
  class ChatPendingActionsController < ApplicationController
    before_action :load_repository
    before_action :load_chat_session
    before_action :load_pending_action

    def confirm
      if @pending_action.confirm!
        redirect_to repository_chats_path(@repository), notice: "Pending action confirmed."
      else
        redirect_to repository_chats_path(@repository), alert: "Pending action is no longer active."
      end
    rescue ActiveRecord::RecordNotFound, ArgumentError => e
      redirect_to repository_chats_path(@repository), alert: e.message
    end

    def destroy
      if @pending_action.reject!
        redirect_to repository_chats_path(@repository), notice: "Pending action rejected."
      else
        redirect_to repository_chats_path(@repository), alert: "Pending action is no longer active."
      end
    end

    private

    def load_repository
      @repository = Current.user.repositories.find(params[:repository_id])
    end

    def load_chat_session
      @chat_session = @repository.chat_sessions.find(params[:chat_id])
    end

    def load_pending_action
      @pending_action = @chat_session.pending_actions.find(params[:id])
    end
  end
end
