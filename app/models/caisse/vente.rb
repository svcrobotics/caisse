# app/models/caisse/vente.rb
module Caisse
  class Vente < ::ApplicationRecord
    self.table_name = "ventes"

    # Associations
    belongs_to :client, optional: true
    belongs_to :versement, optional: true

    has_many :avoir, dependent: :destroy

    has_many :ventes_produits, class_name: "::VentesProduit", dependent: :destroy
    has_many :produits, through: :ventes_produits

    has_and_belongs_to_many :versements

    accepts_nested_attributes_for :ventes_produits, allow_destroy: true

    # Callbacks
    before_save  :calculer_total # alimente la colonne `total` depuis les lignes
    after_commit :mettre_a_jour_produits_vendus

    # Validations métier déjà en place
    validates :motif_annulation, presence: true, if: :annulee?

    # Validations de paiement (pas si vente annulée)
    validate :au_moins_un_mode_de_paiement, unless: :annulee?
    validate :paiement_couvre_reste,         unless: :annulee?

    # ==== Méthodes auxiliaires =================================================

    # NOTE: on n'utilise plus :remise_globale_manuel ici, le contrôleur écrit
    # directement la colonne `remise_globale` et surtout `total_net`.
    # attr_accessor :remise_globale_manuel

    def avoir_utilise
      Avoir.find_by(vente_id: id, utilise: true)
    end

    def avoir_emis
      Avoir.where(vente_id: id, utilise: false)
           .where("remarques LIKE ?", "%Solde restant%").first
    end

    def clients_deposants
      produits.map(&:client).uniq
    end

    def versement_effectue?
      versements.exists?
    end

    # Totaux côté lignes (brut)
    def total_ttc
      ventes_produits.sum { |vp| vp.quantite * vp.prix_unitaire }
    end

    def total_remises
      ventes_produits.sum(&:remise)
    end

    # Paiements: nil => 0
    def cb     = super || 0
    def amex   = super || 0
    def espece = super || 0
    def cheque = super || 0

    # ----- Base due (montant à couvrir par les paiements) ----------------------
    #
    # On s'aligne sur le contrôleur:
    # - `total_net` est déjà "après remises + après avoir"
    # - sinon, fallback sur `total` (ou calcul des lignes)
    #
    def montant_du
      if respond_to?(:total_net) && !total_net.nil?
        total_net.to_d
      else
        # fallback: total (colonne) ou calculé depuis les lignes
        (total || total_ttc).to_d - (respond_to?(:remise_globale) ? (remise_globale || 0) : 0)
      end.clamp(0, BigDecimal("1e12"))
    end

    # Somme réellement saisie dans les modes de paiement
    def montant_regle
      cb.to_d + espece.to_d + cheque.to_d + amex.to_d
    end

    # Au moins un moyen > 0 ?
    def modes_de_paiement_non_nuls?
      [cb, espece, cheque, amex].any? { |v| v.to_d.positive? }
    end

    private

    # Met à jour la colonne `total` depuis les lignes (brut, sans remises % ligne)
    # NB: tu calcules `total_brut/total_net` dans le contrôleur; ici on garde
    # `total` pour compat/fallback.
    def calculer_total
      self.total = ventes_produits.sum { |vp| vp.quantite * vp.prix_unitaire }
    end

    # Marque les produits vendus si en dépôt
    def mettre_a_jour_produits_vendus
      produits.each do |produit|
        produit.update(vendu: true) if produit.en_depot?
      end
    end

    # ----- Règles de validation paiement ---------------------------------------

    # A/ Si montant dû > 0, il faut au moins un mode de paiement
    def au_moins_un_mode_de_paiement
      return if montant_du.zero? # total couvert par avoir/remises => pas de paiement requis
      return if modes_de_paiement_non_nuls?

      errors.add(:base, "Au moins un mode de paiement est obligatoire.")
    end

    # B/ Les montants saisis doivent couvrir le dû (on autorise le rendu)
    def paiement_couvre_reste
      return if montant_du.zero?
      return if montant_regle >= montant_du

      errors.add(
        :base,
        "Le montant réglé (#{format('%.2f', montant_regle)} €) est insuffisant : " \
        "reste à payer #{format('%.2f', montant_du)} €."
      )
    end
  end
end
