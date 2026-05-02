Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token
  resources :users, only: %i[ new create ]

  resource :credentials, only: %i[ edit update ]
  resources :repositories, except: %i[ show ] do
    collection do
      get :branches
    end
    member do
      post :poll
      post :archive
      post :unarchive
    end
  end
  resources :invitations, only: %i[ index create destroy ]
  resource :settings, only: %i[ edit update ]
  resources :jobs, only: %i[ show ] do
    member do
      post :run_again      # soft replay — new Run on the existing branch
      post :restart        # hard reset — close this thread, open a new one with a fresh branch + PR
      post :cancel         # cancel active runs + close the thread
      post :reopen         # undo a close — closed → open, polling resumes
      post :poll_feedback  # manually trigger PollPullRequestJob for this Job
      post :rebase         # manually trigger a rebase Run on this Job's PR
      post :check_mergeability  # ask GitHub for the latest mergeable status now
    end
  end

  root "home#index"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end
