Caisse::Engine.routes.draw do
  resources :ventes do
    collection do
      get :export
      post :recherche_produit
      post :retirer_produit
      post :modifier_quantite
      post :modifier_prix
    end

    member do
      get :imprimer_ticket
      patch :annuler
      get 'remboursement/:produit_id', to: 'ventes#remboursement', as: 'remboursement_produit'
      patch :rembourser_produit
      post :rembourser_produit
    end
  end

  get "verifier_avoir", to: "ventes#verifier_avoir"
  post "ventes/modifier_remise", to: "ventes#modifier_remise", as: :modifier_remise_ventes
  
  resources :clotures do
    get :imprimer, on: :member
    get :preview, on: :member
    post :cloture_z, on: :collection
    post :cloture_mensuelle, on: :collection
    get :refresh_fond_caisse, on: :collection 
  end

  
  resources :remboursements, only: [:index]
  


end
