module Caisse
  class RemboursementsController < ApplicationController
    def index
      @aujourd_hui = Date.today

      # On force l'utilisation du modèle global ::Remboursement (table "remboursements")
      @remboursements = Caisse::Remboursement
                        .includes(:vente)
                        .where(date: @aujourd_hui)
                        .order(created_at: :desc)

      # Pour les mouvements d'espèces, pas de changement nécessaire :
      @mouvements_especes = MouvementEspece
                            .where(date: @aujourd_hui, sens: "sortie")
                            .order(created_at: :desc)
    end
  end
end