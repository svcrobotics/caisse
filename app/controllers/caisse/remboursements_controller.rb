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

    def create
      remboursement = Caisse::Remboursement.create!(remboursement_params)

      produit = Produit.find(params[:produit_id])

      # 🔐 Enregistrement du remboursement produit dans la blockchain
      Blockchain::Service.add_block({
        vente_id: remboursement.vente.id,
        type: 'Remboursement produit',
        produits: [
          {
            nom: produit.nom,
            quantite: 1,
            prix: produit.prix
          }
        ],
        remboursement: remboursement.mode,
        motif: remboursement.motif,
        client: remboursement.vente.client&.nom
      })

      redirect_to caisse_remboursements_path, notice: "✅ Remboursement enregistré et certifié"
    end

    private

    def remboursement_params
      params.require(:remboursement).permit(:vente_id, :mode, :montant, :motif, :date)
    end

  end
end