# app/models/caisse/vente.rb
module Caisse
  class Vente < ::ApplicationRecord
    self.table_name = "ventes"

    # ── Associations ─────────────────────────────────────────────────────────────
    belongs_to :client, optional: true
    belongs_to :versement, optional: true

    has_one :avoir, dependent: :destroy

    has_many :ventes_produits, class_name: "::VentesProduit", dependent: :destroy
    has_many :produits, through: :ventes_produits

    has_and_belongs_to_many :versements

    accepts_nested_attributes_for :ventes_produits, allow_destroy: true

    # ── Callbacks ───────────────────────────────────────────────────────────────
    before_save :calculer_total
    after_commit :mettre_a_jour_produits_vendus

    # ── Validations existantes ──────────────────────────────────────────────────
    validates :motif_annulation, presence: true, if: :annulee?

    # ── Validations paiement ────────────────────────────────────────────────────
    validate :au_moins_un_mode_de_paiement, unless: :annulee?
    validate :paiement_couvre_reste,         unless: :annulee?

    # ── Méthodes spécifiques ────────────────────────────────────────────────────

    # Avoir utilisé (côté vente)
    def avoir_utilise
      Avoir.find_by(vente_id: id, utilise: true)
    end

    # Avoir émis pour solde restant (si négatif après utilisation)
    def avoir_emis
      Avoir.where(vente_id: id, utilise: false)
           .where("remarques LIKE ?", "%Solde restant%").first
    end

    # Premier paiement (si tu as un modèle Paiement à terme)
    def paiement
      paiements.first
    end

    def clients_deposants
      produits.map(&:client).uniq
    end

    def versement_effectue?
      versements.exists?
    end

    # Totaux “bruts” côté lignes
    def total_ttc
      ventes_produits.sum { |vp| vp.quantite * vp.prix_unitaire }
    end

    def total_remises
      ventes_produits.sum(&:remise)
    end

    # Champs de paiement : nil → 0
    def cb     = super || 0
    def amex   = super || 0
    def espece = super || 0
    def cheque = super || 0

    # ── Aides de calcul (paiement) ──────────────────────────────────────────────

    # Total de la vente (prend la colonne total si déjà calculée, sinon recalcule)
    def montant_total
      (total || total_ttc).to_d
    end

    # Montant d’avoir imputé à cette vente
    def montant_avoir_utilise
      (avoir_utilise&.montant || 0).to_d
    end

    # Montant restant à encaisser après avoir (jamais négatif)
    def reste_a_payer
      [montant_total - montant_avoir_utilise, 0.to_d].max
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

    # Recalcule le total depuis les lignes
    def calculer_total
      self.total = ventes_produits.sum { |vp| vp.quantite * vp.prix_unitaire }
    end

    # Marque les produits “vendu: true” si en dépôt
    def mettre_a_jour_produits_vendus
      produits.each do |produit|
        produit.update(vendu: true) if produit.en_depot?
      end
    end

    # ── Règles de validation paiement ───────────────────────────────────────────

    # A/ Si reste > 0, il faut au moins un mode de paiement
    def au_moins_un_mode_de_paiement
      return if reste_a_payer.zero? # l’avoir couvre tout → pas de paiement requis
      return if modes_de_paiement_non_nuls?

      errors.add(:base, "Au moins un mode de paiement est obligatoire.")
    end

    # B/ Les montants saisis doivent couvrir le reste (on autorise le rendu)
    def paiement_couvre_reste
      return if reste_a_payer.zero? # couvert intégralement par l’avoir
      return if montant_regle >= reste_a_payer

      errors.add(
        :base,
        "Le montant réglé (#{sprintf('%.2f', montant_regle)} €) est insuffisant : " \
        "reste à payer #{sprintf('%.2f', reste_a_payer)} €."
      )
    end
  end
end
