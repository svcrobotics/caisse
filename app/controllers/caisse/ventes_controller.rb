module Caisse
  class VentesController < ApplicationController 
    before_action :set_vente, only: %i[show destroy imprimer_ticket]

    def index
      @ventes = Caisse::Vente.includes(ventes_produits: :produit).order(date_vente: :desc)

      if params[:numero].present?
        @ventes = @ventes.where(id: params[:numero].to_i)
      end

      if params[:date].present?
        date = Date.parse(params[:date]) rescue nil
        @ventes = @ventes.where(date_vente: date.all_day) if date
      end

      if params[:code_barre].present?
        @ventes = @ventes.joins(ventes_produits: :produit)
                         .where(produits: { code_barre: params[:code_barre] })
                         .distinct
      end

      if params[:client_nom].present?
        @ventes = @ventes.joins(:client).where("clients.nom LIKE ?", "%#{params[:client_nom]}%")
      end

      today = Date.current.all_day
      this_month = Date.current.beginning_of_month..Date.current.end_of_month

      @stats = {
        today_count: Caisse::Vente.where(date_vente: today).count,
        today_total: Caisse::Vente.where(date_vente: today).sum(:total_net),
        month_count: Caisse::Vente.where(date_vente: this_month).count,
        month_total: Caisse::Vente.where(date_vente: this_month).sum(:total_net)
      }
    end

    def show
      @vente = Vente
        .includes(ventes_produits: { produit: :fournisseur })
        .find(params[:id])

      @avoir_utilise = Avoir.find_by(vente_id: @vente.id, utilise: true)
      @avoir_emis    = Avoir.find_by(vente_id: @vente.id, utilise: false)

      # Calcul du reste à payer après utilisation de l'avoir (à titre indicatif)
      @reste = @vente.total_net - (@avoir_utilise&.montant.to_d || 0)
    end

    def new
      @vente = Caisse::Vente.new
      @vente.client = lookup_client_from_params
      @vente.cb     = params[:cb].to_d if params[:cb].present?
      @vente.espece = params[:espece].to_d if params[:espece].present?
      @vente.cheque = params[:cheque].to_d if params[:cheque].present?
      @vente.amex   = params[:amex].to_d if params[:amex].present?

      @total = calculer_total_session

      # Gestion de l’avoir
      @avoir = Avoir.find_by(id: params[:avoir_id]) if params[:avoir_id].present?
      @total_net = (@total - (@avoir&.montant || 0)).clamp(0, Float::INFINITY)

      @avoirs_valides = Avoir.where(utilise: false)
                             .where("created_at >= ?", 1.year.ago)
                             .order(created_at: :desc)

      if params[:code_barre].present?
        code = correct_scanner_input(params[:code_barre])
        produit = Produit.find_by(code_barre: code)

        if produit
          produit.update(stock: 1) if produit.stock <= 0

          id = produit.id.to_s
          session[:ventes] ||= {}
          session[:ventes][id] ||= {
            "quantite" => 0,
            "prix" => produit.prix_affiche.to_d,
            "remise" => 0.to_d
          }
          session[:ventes][id]["quantite"] += 1

          redirect_to new_vente_path(client_nom: params[:client_nom], client_id:  params[:client_id], avoir_id: params[:avoir_id]) and return
        else
          flash[:alert] = "Produit introuvable avec le code-barres : #{params[:code_barre]}"
        end
      end

      @ventes = session[:ventes] || {}

      @quantites = @ventes.to_h.transform_keys(&:to_i).transform_values { |v| v["quantite"].to_i }
      @prix_unitaire = @ventes.to_h.transform_keys(&:to_i).transform_values { |v| v["prix"].to_d }
      @produits = Produit.where(id: @quantites.keys).index_by(&:id)
    end

    def annuler
      @vente = Caisse::Vente.find(params[:id])

      # 1) Si la vente est déjà annulée, on stoppe tout
      if @vente.annulee?
        redirect_to ventes_path, alert: "❌ La vente n°#{@vente.id} est déjà annulée." and return
      end

      # 2) Marquer la vente comme annulée
      @vente.update!(annulee: true, motif_annulation: params[:motif_annulation])

      # 3) Remettre les produits en stock
      @vente.ventes_produits.each do |vp|
        # Remettre le stock total
        vp.produit.increment!(:stock, vp.quantite)

        # Remettre le stock de la taille vendue
        if vp.produit_taille.present?
          vp.produit_taille.increment!(:stock, vp.quantite)
        end
      end

      # Supprimer les interactions de vente liées à la vente annulée
      @vente.ventes_produits.each do |vp|
        ProduitInteraction.where(
          ventes_produit_id: vp.id,
          type_interaction: "vendu"
        ).delete_all
      end

      # 4) Déterminer le mode de remboursement
      mode_remboursement = case params[:remboursement]
                           when "especes" then "espèces"
                           when "cb"      then "cb"
                           when "avoir"   then "avoir"
                           else                "aucun"
                           end

      montant_total_rembourse = @vente.total_net.round(2)
      motif_remb = "Annulation vente n°#{@vente.id} — #{params[:motif_annulation]}"

      # 5) Enregistrer le remboursement
      Remboursement.create!(
        vente:         @vente,
        montant:       montant_total_rembourse,
        date:          Date.today,
        mode: mode_remboursement,
        motif:         motif_remb
      )

      # 6) Remboursement en espèces (si paiement en espèces)
      if @vente.espece.to_f > 0 && params[:remboursement] == "especes"
        MouvementEspece.create!(
          date:    Date.today,
          sens:    "sortie",
          montant: @vente.espece.round(2),
          motif:   "Remboursement espèces — vente n°#{@vente.id} — #{params[:motif_annulation]}",
          compte:  nil,
          vente:   @vente
        )
      end

      # 7) Remboursement CB en espèces (cas particulier)
      if @vente.cb.to_f > 0 && params[:remboursement] == "especes"
        MouvementEspece.create!(
          date:    Date.today,
          sens:    "sortie",
          montant: @vente.cb.round(2),
          motif:   "Remboursement CB en espèces — vente n°#{@vente.id} — #{params[:motif_annulation]}",
          compte:  nil,
          vente:   @vente
        )
      end

      # 8) Remboursement par avoir
      if params[:remboursement] == "avoir"
        Avoir.create!(
          client:    @vente.client,
          vente:     @vente,
          montant:   montant_total_rembourse,
          utilise:   false,
          date:      Date.today,
          remarques: "Annulation de la vente n°#{@vente.id}"
        )
      end

      # 9) Ajout dans la blockchain
      Blockchain::Service.add_block({
        vente_id:      @vente.id,
        type:          'Annulation',
        total:         @vente.total_net.to_s,
        client:        @vente.client&.nom,
        remboursement: mode_remboursement,
        motif:         params[:motif_annulation],
        produits: @vente.ventes_produits.map do |vp|
          {
            nom:      vp.produit.nom,
            quantite: vp.quantite,
            prix:     vp.prix_unitaire
          }
        end
      })

      # 10) Fin : redirection
      if mode_remboursement == "avoir"
        redirect_to "/avoirs",
                    notice: "✅ Vente n°#{@vente.id} annulée. Avoir créé avec succès."
      else
        redirect_to ventes_path,
                    notice: "✅ Vente n°#{@vente.id} annulée avec succès. Les produits ont été remis en stock."
      end

    end

    def recherche_produit
      code = correct_scanner_input(params[:code_barre])

      session[:ventes] ||= {}

      # --------------------------------------------------
      # 1. Recherche d'abord une taille de chaussure
      # --------------------------------------------------

      produit_taille = ProduitTaille.find_by(code_barre: code)

      if produit_taille
        produit = produit_taille.produit

        # Une ligne de panier doit être unique par taille.
        #
        # Exemple :
        # produit 923 / taille 38
        # produit 923 / taille 39
        #
        # doivent être deux lignes différentes.
        panier_id = "taille_#{produit_taille.id}"

        if session[:ventes][panier_id].is_a?(Hash)
          session[:ventes][panier_id]["quantite"] += 1
        else
          session[:ventes][panier_id] = {
            "produit_id" => produit.id,
            "produit_taille_id" => produit_taille.id,
            "taille" => produit_taille.taille,
            "quantite" => 1,
            "prix" => (
              produit.en_promo? && produit.prix_promo.present? ?
                produit.prix_promo :
                produit.prix
            ).to_d,
            "remise" => 0.to_d
          }
        end

      else

        # --------------------------------------------------
        # 2. Ancien fonctionnement
        #    vêtements / accessoires / anciens produits
        # --------------------------------------------------

        produit = Produit.find_by(code_barre: code)

        if produit
          produit.update(stock: 1) if produit.stock <= 0

          panier_id = produit.id.to_s

          if session[:ventes][panier_id].is_a?(Hash)
            session[:ventes][panier_id]["quantite"] += 1
          else
            session[:ventes][panier_id] = {
              "produit_id" => produit.id,
              "produit_taille_id" => nil,
              "quantite" => 1,
              "prix" => (
                produit.en_promo? && produit.prix_promo.present? ?
                  produit.prix_promo :
                  produit.prix
              ).to_d,
              "remise" => 0.to_d
            }
          end
        end
      end

      # --------------------------------------------------
      # Préparation de l'affichage
      # --------------------------------------------------

      produit_ids = session[:ventes].values
        .select { |infos| infos.is_a?(Hash) }
        .map { |infos| infos["produit_id"] }
        .compact
        .uniq

      @produits = Produit.where(id: produit_ids).index_by(&:id)

      @quantites = session[:ventes].transform_values do |infos|
        infos.is_a?(Hash) ? infos["quantite"].to_i : infos.to_i
      end

      respond_to do |format|
        format.turbo_stream

        format.html do
          redirect_to new_vente_path(
            client_nom: params[:client_nom],
            client_id: params[:client_id],
            avoir_id: params[:avoir_id]
          )
        end
      end
    end

    def retirer_produit
      panier_id = params[:produit_id].to_s

      session[:ventes] ||= {}
      session[:ventes].delete(panier_id)

      produit_ids = session[:ventes].values.filter_map do |infos|
        next unless infos.is_a?(Hash)

        infos["produit_id"]
      end.uniq

      @produits = Produit.where(id: produit_ids).index_by(&:id)

      @quantites = session[:ventes].transform_values do |infos|
        infos.is_a?(Hash) ? infos["quantite"].to_i : infos.to_i
      end

      respond_to do |format|
        format.turbo_stream { render "recherche_produit" }

        format.html do
          redirect_to new_vente_path(
            client_nom: params[:client_nom],
            client_id: params[:client_id],
            avoir_id: params[:avoir_id]
          )
        end
      end
    end

    def modifier_remise
      panier_id = params[:produit_id].to_s
      remise = params[:remise].to_d

      session[:ventes] ||= {}

      ligne = session[:ventes][panier_id]

      unless ligne
        redirect_to new_vente_path,
                    alert: "Ligne de panier introuvable."
        return
      end

      # Compatibilité ancien format éventuel
      if ligne.is_a?(Integer)
        produit = Produit.find_by(id: panier_id)

        ligne = {
          "produit_id" => produit&.id,
          "produit_taille_id" => nil,
          "quantite" => ligne,
          "prix" => produit&.prix_affiche.to_d,
          "remise" => 0.to_d
        }

        session[:ventes][panier_id] = ligne
      end

      ligne["remise"] = remise

      produit_ids = session[:ventes].values.filter_map do |infos|
        next unless infos.is_a?(Hash)

        infos["produit_id"]
      end.uniq

      @produits = Produit.where(id: produit_ids).index_by(&:id)

      @quantites = session[:ventes].transform_values do |infos|
        infos.is_a?(Hash) ? infos["quantite"].to_i : infos.to_i
      end

      respond_to do |format|
        format.turbo_stream { render "recherche_produit" }

        format.html do
          redirect_to new_vente_path(
            client_nom: params[:client_nom],
            client_id: params[:client_id],
            avoir_id: params[:avoir_id]
          )
        end
      end
    end

    def create
      # Panier en session obligatoire
      session[:ventes] ||= {}
      ventes_data = session[:ventes]
      if ventes_data.blank?
        redirect_to new_vente_path, alert: "Aucun produit à encaisser."
        return
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # 1) Préparation des lignes + totaux
      # ─────────────────────────────────────────────────────────────────────────────
      client = lookup_client_from_params
      total_brut     = 0.to_d
      total_net_lignes = 0.to_d
      lignes         = []

      ventes_data.each do |panier_id, infos|
        next unless infos.is_a?(Hash)

        produit_id = infos["produit_id"]

        # Compatibilité avec l'ancien panier
        produit_id ||= panier_id if panier_id.to_s.match?(/\A\d+\z/)

        produit = Produit.find(produit_id)

        produit_taille =
          if infos["produit_taille_id"].present?
            ProduitTaille.find(infos["produit_taille_id"])
          end

        qte        = infos["quantite"].to_i
        pu         = infos["prix"].to_d
        remise_pct = infos["remise"].to_d

        # Sécurité stock pour les chaussures
        if produit_taille.present? && produit_taille.stock.to_i < qte
          redirect_to new_vente_path,
                      alert: "Stock insuffisant pour #{produit.nom} taille #{produit_taille.taille}."
          return
        end

        # Sécurité stock pour les autres produits
        if produit_taille.nil? && produit.stock.to_i < qte
          redirect_to new_vente_path,
                      alert: "Stock insuffisant pour #{produit.nom}."
          return
        end

        montant_brut = pu * qte
        remise_euros = (montant_brut * (remise_pct / 100)).round(2)
        montant_net  = (montant_brut - remise_euros).round(2)

        lignes << {
          produit: produit,
          produit_taille: produit_taille,
          quantite: qte,
          prix_unitaire: pu,
          remise: remise_pct
        }

        total_brut       += montant_brut
        total_net_lignes += montant_net
      end

      # Base de calcul: total net après remises LIGNES
      total_net = total_net_lignes

      # ─────────────────────────────────────────────────────────────────────────────
      # 2) Avoir (utilisation éventuelle)
      # ─────────────────────────────────────────────────────────────────────────────
      avoir_utilise = nil
      reste_credit  = nil
      montant_avoir = 0.to_d

      if params[:avoir_id].present?
        avoir_utilise = Avoir.find_by(id: params[:avoir_id], utilise: false)
        if avoir_utilise && (avoir_utilise.created_at >= 1.year.ago)
          montant_avoir = avoir_utilise.montant.to_d
          reste = total_net - montant_avoir
          if reste <= 0
            reste_credit = (montant_avoir - total_net).round(2) # on émettra un nouvel avoir
            total_net    = 0.to_d
            flash[:notice] ||= "✅ Vente à 0 € enregistrée via l’avoir."
          else
            total_net = reste.round(2)
          end
        end
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # 3) Remise globale manuelle (valeur en € depuis la vue)
      #    + éventuellement un "total_final_manuel" si tu l'utilises encore
      # ─────────────────────────────────────────────────────────────────────────────
      remise_globale = 0.to_d

      if params[:total_final_manuel].present?
        total_final_manuel = params[:total_final_manuel].to_d
        if total_final_manuel < total_net
          remise_globale += (total_net - total_final_manuel).round(2)
          total_net       = total_final_manuel
        end
      end

      if params[:remise_globale_manuel].present?
        remise_globale += params[:remise_globale_manuel].to_d
        total_net       = [total_net - params[:remise_globale_manuel].to_d, 0].max
      end

      # ─────────────────────────────────────────────────────────────────────────────
      # 4) Montants de paiement (sécurisés)
      # ─────────────────────────────────────────────────────────────────────────────
      cb     = (params[:cb]     || 0).to_d
      espece = (params[:espece] || 0).to_d
      cheque = (params[:cheque] || 0).to_d
      amex   = (params[:amex]   || 0).to_d

      # ─────────────────────────────────────────────────────────────────────────────
      # 5) Création de la vente
      # ─────────────────────────────────────────────────────────────────────────────
      @vente = Caisse::Vente.new(
        client:         client,
        date_vente:     Time.current,
        total_brut:     total_brut.round(2),
        total_net:      total_net.round(2),
        remise_globale: remise_globale.round(2),
        cb:     cb,
        espece: espece,
        cheque: cheque,
        amex:   amex
      )
      lignes.each { |vp| @vente.ventes_produits.build(vp) }

      if @vente.save
        # ───────────────────────────────────────────────────────────────────────────
        # 6) Blockchain (journalisation)
        # ───────────────────────────────────────────────────────────────────────────
        Blockchain::Service.add_block({
          vente_id: @vente.id,
          produits: @vente.ventes_produits.map { |ligne|
            { nom: ligne.produit.nom, quantite: ligne.quantite, prix: ligne.prix_unitaire }
          },
          total:  @vente.total_net.to_s,
          client: @vente.client&.nom,
          type:   'Vente'
        })

        # ───────────────────────────────────────────────────────────────────────────
        # 7) Stock: décrémenter
        # ───────────────────────────────────────────────────────────────────────────
        @vente.ventes_produits.each do |vp|
          # Stock total du produit
          vp.produit.decrement!(:stock, vp.quantite)

          # Stock de la taille pour les chaussures
          if vp.produit_taille.present?
            vp.produit_taille.decrement!(:stock, vp.quantite)
          end
        end

        # --------------------------------------------------
        # Enregistrer les ventes pour l'analyse IA boutique
        # --------------------------------------------------

        @vente.ventes_produits.each do |vp|
          prix_reference = vp.produit.prix.to_d

          prix_apres_remise =
            (
              vp.prix_unitaire.to_d *
              (1 - vp.remise.to_d / 100)
            ).round(2)

          ProduitInteraction.create!(
            produit: vp.produit,
            produit_taille: vp.produit_taille,
            ventes_produit: vp,
            type_interaction: "vendu",
            quantite: vp.quantite,
            prix_reference: prix_reference,
            prix_vendu: prix_apres_remise,
            remise_pct: vp.remise.to_d
          )
        end

        # ───────────────────────────────────────────────────────────────────────────
        # 8) Mouvements espèces: entrée et rendu le cas échéant
        # ───────────────────────────────────────────────────────────────────────────
        if @vente.espece.to_f > 0
          # Entrée espèces
          MouvementEspece.create!(
            sens:    "entrée",
            motif:   "Paiement client - Vente n°#{@vente.id}",
            montant: @vente.espece.round(2),
            date:    @vente.date_vente,
            compte:  nil,
            vente_id: @vente.id
          )

          # Rendu éventuel
          total_verse = @vente.espece.to_d + @vente.cb.to_d + @vente.cheque.to_d + @vente.amex.to_d + montant_avoir.to_d
          rendu = (total_verse - @vente.total_net.to_d).round(2)
          if rendu.positive?
            MouvementEspece.create!(
              sens:    "sortie",
              motif:   "Rendu monnaie - Vente n°#{@vente.id}",
              montant: rendu,
              date:    @vente.date_vente,
              compte:  nil,
              vente_id: @vente.id
            )
          end
        end

        # ───────────────────────────────────────────────────────────────────────────
        # 9) Avoir: marquer utilisé + émettre un nouvel avoir si crédit
        # ───────────────────────────────────────────────────────────────────────────
        if avoir_utilise
          avoir_utilise.update!(utilise: true, vente: @vente)
        end

        if reste_credit && reste_credit > 0 && avoir_utilise&.client
          Avoir.create!(
            client:    avoir_utilise.client,
            vente_id:  @vente.id,
            montant:   reste_credit,
            utilise:   false,
            date:      Date.today,
            remarques: "Solde restant de l’avoir n°#{avoir_utilise.id}"
          )
        end

        # ───────────────────────────────────────────────────────────────────────────
        # 10) Fin: nettoyer la session et rediriger
        # ───────────────────────────────────────────────────────────────────────────
        session[:ventes] = {}
        redirect_to ventes_path, notice: "✅ Vente enregistrée avec succès."
      else
        # ───────────────────────────────────────────────────────────────────────────
        # Échec validations → réafficher la page "new" avec les bons jeux de données
        # ───────────────────────────────────────────────────────────────────────────
        @vente.client = client
        @total        = calculer_total_session

        @avoir        = Avoir.find_by(id: params[:avoir_id]) if params[:avoir_id].present?
        @total_net    = (@total - (@avoir&.montant || 0)).clamp(0, Float::INFINITY)

        @avoirs_valides = Avoir.where(utilise: false)
                               .where("created_at >= ?", 1.year.ago)
                               .order(created_at: :desc)

        ventes_data   = session[:ventes] || {}
        @quantites    = ventes_data.transform_keys(&:to_i).transform_values { |v| v["quantite"].to_i }
        @produits     = Produit.where(id: @quantites.keys).index_by(&:id)

        flash.now[:alert] = @vente.errors.full_messages.join("<br>").html_safe
        render :new, status: :unprocessable_entity
      end
    end

    def verifier_avoir
      @avoir = Avoir.find_by(id: params[:avoir_id])
      @total_vente = calculer_total_session # une méthode que tu vas créer
      render partial: "infos_avoir"
    end

    def destroy
      @vente = Caisse::Vente.find(params[:id])
      @vente.destroy
      redirect_to ventes_path, notice: "Vente supprimée avec succès."
    end

    def imprimer_ticket
      imprimer_ticket_texte(@vente)
      redirect_to ventes_path, notice: "Ticket imprimé avec succès."
    end

    def export
      require "caxlsx_rails"

      mois = params[:mois] || (Date.today << 1).strftime("%Y-%m")
      date_debut = Date.parse("#{mois}-01")
      date_fin   = date_debut.end_of_month.end_of_day

      ventes = Caisse::Vente
                 .includes(ventes_produits: { produit: :client }, client: {}, versements: {})
                 .where(date_vente: date_debut..date_fin)

      # Exclure les ventes annulées selon la colonne disponible
      cols = Caisse::Vente.column_names
      ventes =
        if cols.include?("annulee")
          ventes.where(annulee: [false, nil])
        elsif cols.include?("annulee_at")
          ventes.where(annulee_at: nil)
        elsif cols.include?("status")
          ventes.where.not(status: %w[annule annulee canceled])
        elsif cols.include?("etat")
          ventes.where.not(etat: %w[annule annulee canceled])
        else
          ventes
        end

      # ⚡ Précharge tous les avoirs (utilisés et émis) pour les ventes du périmètre
      vente_ids = ventes.pluck(:id)
      avoirs_utilises_by_vente = Avoir.where(vente_id: vente_ids, utilise: true).group_by(&:vente_id)
      avoirs_emis_by_vente     = Avoir.where(vente_id: vente_ids, utilise: false).group_by(&:vente_id)

      p  = Axlsx::Package.new
      wb = p.workbook

      wb.add_worksheet(name: "Ventes #{mois}") do |sheet|
        sheet.add_row [
          "Date de vente", "Numéro de la vente", "Nom du produit", "Catégorie", "État",
          "Taux de TVA", "Prix d'achat", "Prix déposant", "Quantité", "Remise (€)", "Total déposant",
          "Prix vente TTC (net)", "Marge", "Nom de la déposante", "Date de versement", "Reçu",
          "Mode de paiement cliente", "Mode de versement déposante",
          "Avoir utilisé n°", "Montant avoir utilisé",
          "Avoir émis n°", "Montant avoir émis"
        ]

        ventes.each do |vente|
          # Déduire le mode de paiement réel (multi)
          paiements = []
          paiements << "CB"      if vente.cb.to_d     > 0
          paiements << "Espèces" if vente.espece.to_d > 0
          paiements << "Chèque"  if vente.cheque.to_d > 0
          paiements << "AMEX"    if vente.amex.to_d   > 0
          mode_paiement = paiements.join(" + ")

          # 🔎 Récup avoirs pour cette vente (utilisés & émis) — gère 0..n éléments
          au = (avoirs_utilises_by_vente[vente.id] || [])
          ae = (avoirs_emis_by_vente[vente.id]     || [])

          au_ids      = au.map(&:id).join(", ")
          au_montants = au.map { |a| sprintf("%.2f", a.montant.to_d) }.join(" + ")

          ae_ids      = ae.map(&:id).join(", ")
          ae_montants = ae.map { |a| sprintf("%.2f", a.montant.to_d) }.join(" + ")

          vente.ventes_produits.each do |vp|
            produit        = vp.produit
            quantite       = vp.quantite
            prix_unit      = vp.prix_unitaire
            prix_achat     = produit.prix_achat
            prix_deposante = produit.prix_deposant || 0
            total_deposant = quantite * prix_deposante
            remise_pct     = vp.remise.to_d
            total_brut     = prix_unit * quantite
            remise_euros   = (total_brut * remise_pct / 100).round(2)
            total_ttc      = total_brut - remise_euros

            deposante = produit.client if produit.en_depot?
            versement = if deposante
                           Versement.joins(:ventes).where(ventes: { id: vente.id }, client: deposante).first
                         end

            # TVA
            if produit.etat == "neuf"
              tva      = (total_ttc / 1.2 * 0.2).round(2)
              taux_tva = "20%"
            else
              tva      = 0
              taux_tva = "0%"
            end

            total_ht = (total_ttc - tva).round(2)

            # Marge réelle
            marge =
              if produit.en_depot?
                total_ttc - (prix_deposante * quantite)
              elsif produit.etat == "occasion"
                total_ttc - ((prix_achat || 0) * quantite)
              else
                total_ttc
              end

            nom_deposante   = deposante ? "#{deposante.prenom} #{deposante.nom}" : "N/A"
            date_versement  = versement&.created_at&.strftime("%d/%m/%Y") || "N/A"
            numero_recu     = versement&.numero_recu || "N/A"
            methode_versement = versement&.methode_paiement || "N/A"

            sheet.add_row [
              vente.date_vente.strftime("%Y-%m-%d"),
              vente.id,
              produit.nom,
              produit.categorie,
              produit.etat,
              taux_tva,
              sprintf("%.2f", prix_achat || 0),
              sprintf("%.2f", prix_deposante || 0),
              quantite,
              sprintf("%.2f", remise_euros),
              sprintf("%.2f", total_deposant),
              sprintf("%.2f", total_ttc),
              sprintf("%.2f", marge),
              nom_deposante,
              date_versement,
              numero_recu,
              mode_paiement,
              methode_versement,
              au_ids,
              au_montants,
              ae_ids,
              ae_montants
            ]
          end
        end
      end

      nom_fichier = "ventes_#{mois}.xlsx"
      send_data p.to_stream.read, filename: nom_fichier, type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    end

    def remboursement
      @vente = Caisse::Vente.find(params[:id])
      @produit = Produit.find(params[:produit_id])

      unless @produit.etat == "neuf"
        redirect_to vente_path(@vente), alert: "Seuls les produits neufs peuvent être remboursés."
        return
      end
    end

    def rembourser_produit
      @vente = Caisse::Vente.find(params[:id])
      @produit = Produit.find(params[:produit_id])
      quantite_remb = params[:quantite].to_i
      motif = params[:motif] || "Sans motif"

      vp = @vente.ventes_produits.find_by(produit_id: @produit.id)

      unless vp && @produit.etat == "neuf" && quantite_remb.between?(1, vp.quantite)
        redirect_to vente_path(@vente), alert: "Produit invalide, non remboursable ou quantité incorrecte."
        return
      end

      Caisse::Vente.transaction do
        # Re-crédit du stock
        @produit.update!(stock: @produit.stock + quantite_remb)

        # Prix unitaire
        prix_unitaire = vp.prix_unitaire.to_d > 0 ? vp.prix_unitaire.to_d : @produit.prix.to_d
        total_brut = prix_unitaire * quantite_remb

        # Remise produit
        remise_produit = (total_brut * vp.remise.to_d / 100).round(2)
        net_apres_remise = total_brut - remise_produit

        # Base pour la remise globale
        total_net_produits = @vente.ventes_produits.sum do |vpr|
          pu = vpr.prix_unitaire.to_d > 0 ? vpr.prix_unitaire.to_d : vpr.produit.prix.to_d
          (pu * vpr.quantite * (1 - vpr.remise.to_d / 100))
        end

        # Part de remise globale pour ce produit
        part_remise_globale = if total_net_produits > 0 && @vente.remise_globale.to_d > 0
          (net_apres_remise / total_net_produits) * @vente.remise_globale.to_d
        else
          0
        end

        montant = (net_apres_remise - part_remise_globale).round(2)

        avoir = Avoir.create!(
          client: @vente.client,
          montant: montant,
          date: Date.today,
          motif: "Remboursement #{quantite_remb}x produit ##{@produit.id} : #{motif}",
          vente: @vente
        )

        Blockchain::Service.add_block({
          vente_id: @vente.id,
          type: 'Remboursement produit',
          produits: [
            {
              nom: @produit.nom,
              quantite: quantite_remb,
              prix: prix_unitaire
            }
          ],
          total: montant.to_s,
          remboursement: 'avoir',
          motif: motif,
          client: @vente.client&.nom
        })


        redirect_to vente_path(@vente), notice: "Avoir émis (#{quantite_remb}x) : N°#{avoir.id} — #{montant} €"
      end
    end



    private

    def lookup_client_from_params
      if params[:client_id].present?
        return Client.find_by(id: params[:client_id])
      end

      raw = params[:client_nom].to_s.strip
      return nil if raw.blank? || params[:sans_client] == "1"

      client = Client.where("LOWER(nom) = ?", raw.downcase).first
      return client if client

      matches = Client.where("LOWER(nom) LIKE ?", "%#{raw.downcase}%").limit(2).to_a
      return matches.first if matches.size == 1

      nil
    end

    def calculer_total_session
      ventes_data = session[:ventes] || {}
      ventes_data.sum do |_, infos|
        prix = infos["prix"].to_d
        qte  = infos["quantite"].to_i
        remise = infos["remise"].to_d
        total = prix * qte
        total - (total * remise / 100)
      end.round(2)
    end

    def set_vente
      @vente = Caisse::Vente.find(params[:id])
    end

    def vente_params
      params.require(:vente).permit(:client_id, :mode_paiement,
        ventes_produits_attributes: [ :id, :produit_id, :code_barre, :quantite, :prix_unitaire, :_destroy, :remise_globale_manuel ])
    end

    def correct_scanner_input(input)
      conversion_table = {
        "&" => "1", "é" => "2", '"' => "3", "'" => "4", "(" => "5",
        "-" => "6", "è" => "7", "_" => "8", "ç" => "9", "à" => "0"
      }
      input.chars.map { |char| conversion_table[char] || char }.join.to_i
    end

    def generer_ticket_texte(vente)
      largeur = 42
      montant_col = 10
      lignes = []

      # 🏷️ En-tête boutique
      lignes << "ROMANCE".center(largeur)
      lignes << "C.C. Val Lumière".center(largeur)
      lignes << "5 Rue Jacques Yves Cousteau".center(largeur)
      lignes << "17640 Vaux-sur-Mer".center(largeur)
      lignes << "Tel: ".center(largeur)
      lignes << "-" * largeur
      lignes << "*** VENTE ***".center(largeur)
      lignes << "-" * largeur
      lignes << "Vente n°#{vente.id}"
      lignes << "Date : #{I18n.l(vente.date_vente || vente.created_at)}"
      lignes << "Client : #{vente.client&.nom || 'Sans cliente'}"
      lignes << "-" * largeur

      total_articles = 0
      total_net_sans_remise_globale = vente.ventes_produits.sum do |vp|
        pu = vp.prix_unitaire
        remise_pct = vp.remise.to_d rescue 0.to_d
        quantite = vp.quantite
        montant_brut = pu * quantite
        remise_euros = (montant_brut * (remise_pct / 100)).round(2)
        (montant_brut - remise_euros).round(2)
      end

      vente.ventes_produits.includes(:produit).each do |vp|
        produit = vp.produit

        tva_str = produit.etat == "neuf" ? "TVA 20%" : "TVA 0%"
        ligne_info = "#{produit.categorie.capitalize} - #{produit.etat.capitalize} - #{tva_str}"
        lignes << ligne_info

        lignes << produit.nom[0..41]
        qte = vp.quantite
        pu = vp.prix_unitaire
        remise_pct = vp.remise.to_d rescue 0.to_d

        montant_brut = pu * qte
        remise_euros = (montant_brut * (remise_pct / 100)).round(2)
        montant_net = (montant_brut - remise_euros).round(2)

        # Répartition proportionnelle de la remise globale
        remise_globale = vente.remise_globale.to_d
        part_remise_globale = total_net_sans_remise_globale > 0 ? (montant_net / total_net_sans_remise_globale * remise_globale).round(2) : 0
        montant_net_final = (montant_net - part_remise_globale).round(2)

        lignes << "#{qte.to_s.rjust(10)} x #{format('%.2f €', pu)} => #{format('%.2f €', montant_brut).rjust(10)}"
        
        if remise_euros > 0
          lignes << "- Remise sur le produit : -#{format('%.2f €', remise_euros)} (#{remise_pct.to_i}%)"
        end
        
        if remise_globale > 0
          lignes << "- Remise globale répartie : -#{format('%.2f €', part_remise_globale)}"
          lignes << "> Total net : #{format('%.2f €', montant_net_final)}"
        else
          lignes << "Total net : #{format('%.2f €', montant_net)}"
        end

        lignes << "-" * largeur

        total_articles += qte
      end

      lignes << "-" * largeur
      lignes << "Total articles : #{total_articles}".rjust(largeur)

      # Initialisation des totaux
      ttc_0 = 0
      ttc_20 = 0

      # Calcul TTC net par taux après remises produit
      vente.ventes_produits.includes(:produit).each do |vp|
        produit = vp.produit
        qte = vp.quantite
        pu = vp.prix_unitaire
        remise_pct = vp.remise.to_d
        montant_brut = pu * qte
        remise_euros = (montant_brut * (remise_pct / 100)).round(2)
        montant_net = montant_brut - remise_euros

        if produit.etat == "neuf"
          ttc_20 += montant_net
        else
          ttc_0 += montant_net
        end
      end

      # Application proportionnelle de la remise globale
      remise_globale = vente.respond_to?(:remise_globale) ? vente.remise_globale.to_d : 0
      ttc_total = ttc_0 + ttc_20

      if remise_globale > 0 && ttc_total > 0
        part_20 = (ttc_20 / ttc_total).round(4)
        part_0  = 1 - part_20

        remise_20 = (remise_globale * part_20).round(2)
        remise_0  = (remise_globale * part_0).round(2)

        ttc_20 -= remise_20
        ttc_0  -= remise_0
      end

      # Recalcul des montants HT et TVA
      ht_20     = (ttc_20 / 1.2).round(2)
      tva_20    = (ttc_20 - ht_20).round(2)
      ht_total  = (ht_20 + ttc_0).round(2)
      tva_total = tva_20
      ttc_total = (ttc_20 + ttc_0).round(2)


      lignes << "-" * largeur
      lignes << "Sous-total HT".ljust(largeur - montant_col) + "#{'%.2f €' % ht_total}".rjust(montant_col)
      lignes << "TVA (20%)".ljust(largeur - montant_col) + "#{'%.2f €' % tva_total}".rjust(montant_col)
      if vente.respond_to?(:remise_globale) && vente.remise_globale.to_d > 0
        lignes << "Remise globale".ljust(largeur - montant_col) + "-#{'%.2f €' % vente.remise_globale}".rjust(montant_col)
        lignes << "Remise globale répartie selon le montant"
        lignes << "TTC net de chaque produit de la vente."
      end
      lignes << "-" * largeur
      lignes << "TOTAL TTC".ljust(largeur - montant_col) + "#{'%.2f €' % ttc_total}".rjust(montant_col)
      lignes << "-" * largeur

      # Affichage des paiements
      paiements = []
      avoir_utilise = Avoir.where(vente_id: vente.id, utilise: true).order(:created_at).first
      montant_avoir = avoir_utilise&.montant.to_d || 0
      paiements << ["Avoir utilisé n°#{avoir_utilise.id}", montant_avoir] if montant_avoir > 0

      # ✅ Affichage paiements réels
      somme_payee = 0

      paiements_simples = {
        "CB" => vente.cb.to_d,
        "Espèces" => vente.espece.to_d,
        "Chèque" => vente.cheque.to_d,
        "AMEX" => vente.amex.to_d
      }

      paiements_simples.each do |mode, montant|
        next if montant.zero?

        lignes << mode.ljust(largeur - montant_col) + "-#{'%.2f €' % montant}".rjust(montant_col)
        somme_payee += montant
      end

      # 💶 Calcul du rendu si espèces > à rendre
      rendu = 0
      autres_paiements = vente.cb.to_d + vente.cheque.to_d + vente.amex.to_d
      total_autres = autres_paiements
      reste_apres_autres = ttc_total - total_autres
      rendu = vente.espece.to_d - reste_apres_autres
      rendu = 0 if rendu < 0

      # Reste à payer réel (ne jamais négatif)
      reste_a_payer = (ttc_total - (vente.cb.to_d + vente.cheque.to_d + vente.amex.to_d + vente.espece.to_d)).round(2)
      reste_a_payer = 0 if reste_a_payer < 0

      # 🔻 Affichage dans le ticket
      if rendu > 0
        lignes << "Rendu".ljust(largeur - montant_col) + "#{'%.2f €' % rendu}".rjust(montant_col)
      end

      lignes << "Reste à payer".ljust(largeur - montant_col) + "#{'%.2f €' % reste_a_payer}".rjust(montant_col)

      # 5. Si nouvel avoir émis (avoir utilisé > total TTC)
      if montant_avoir > ttc_total
        nouvel_avoir = Avoir.where(vente_id: vente.id, remarques: "Solde restant de l’avoir n°#{avoir_utilise&.id}").first
        if nouvel_avoir.present?
          lignes << "Avoir émis n°#{nouvel_avoir.id}".ljust(largeur - montant_col) + "#{'%.2f €' % nouvel_avoir.montant}".rjust(montant_col)
        end
      end

      lignes << "-" * largeur
      lignes << format("%-10s%-10s%-10s%-10s", "Taux TVA", "TVA", "HT", "TTC")
      lignes << "-" * largeur
      lignes << format("%-10s%-10s%-10s%-10s", "0%", "#{sprintf('%.2f €', 0)}", "#{sprintf('%.2f €', ttc_0)}", "#{sprintf('%.2f €', ttc_0)}")
      lignes << format("%-10s%-10s%-10s%-10s", "20%", "#{sprintf('%.2f €', tva_20)}", "#{sprintf('%.2f €', ht_20)}", "#{sprintf('%.2f €', ttc_20)}")
      lignes << "-" * largeur
      lignes << format("%-10s%-10s%-10s%-10s", "TOTAL", "#{sprintf('%.2f €', tva_total)}", "#{sprintf('%.2f €', ht_total)}", "#{sprintf('%.2f €', ttc_total)}")

      lignes << ""
      lignes << "Horaires".center(largeur)
      lignes << "Lundi au Samedi 8h30 - 19h30".center(largeur)
      lignes << "Dimanche        8h30 - 12h30".center(largeur)
      lignes << ""
      lignes << "Ouvertures exceptionnelles:".center(largeur)
      lignes << "1 novembre et 11 novembre".center(largeur)
      lignes << ""
      lignes << "Fermeture exceptionnelle:".center(largeur)
      lignes << "25 décembre".center(largeur)
      lignes << ""
      lignes << "Merci de votre visite".center(largeur)
      lignes << "A bientôt".center(largeur)
      lignes << "ROMANCE".center(largeur)
      lignes << "\n" * 10

      lignes.join("\n")
    end

    def encode_with_iconv(text)
      tmp_input  = Rails.root.join("tmp", "ticket_utf8.txt")
      tmp_output = Rails.root.join("tmp", "ticket_cp858.txt")

      File.write(tmp_input, text)
      system("iconv -f UTF-8 -t CP858 #{tmp_input} -o #{tmp_output}")

      tmp_output
    end

    def imprimer_ticket_texte(vente)
      file_to_print = encode_with_iconv(generer_ticket_texte(vente))
      system("lp", "-d", "SEWOO_LKT_Series", file_to_print.to_s)
    end
  end
end
