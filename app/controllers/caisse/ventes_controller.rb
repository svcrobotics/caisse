module Caisse
  class VentesController < ApplicationController
    before_action :set_vente, only: %i[show destroy imprimer_ticket]

    def index
      @ventes = Caisse::Vente.includes(:client).order(created_at: :desc).limit(50)
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
        today_count: Caisse::Vente.where(created_at: today).count,
        today_total: Caisse::Vente.where(created_at: today).sum(:total_net),
        month_count: Caisse::Vente.where(created_at: this_month).count,
        month_total: Caisse::Vente.where(created_at: this_month).sum(:total_net)
      }
    end

    def show
      @vente = Caisse::Vente.find(params[:id])
      @avoir_utilise = Avoir.find_by(vente_id: @vente.id, utilise: true)
      @avoir_emis    = Avoir.find_by(vente_id: @vente.id, utilise: false)

      # Calcul du reste à payer après utilisation de l'avoir (à titre indicatif)
      @reste = if @avoir_utilise
        @vente.total_brut - @avoir_utilise.montant
      else
        @vente.total_brut
      end
    end

    def new
      @vente = Caisse::Vente.new
      @vente.client = Client.find_by(nom: params[:client_nom]) if params[:client_nom].present?

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

          redirect_to new_vente_path(client_nom: params[:client_nom], avoir_id: params[:avoir_id]) and return
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
      @vente.annulee = true
      @vente.motif_annulation = params[:motif_annulation]
      @vente.save!

      # Remet tous les produits en stock
      @vente.ventes_produits.each do |vp|
        vp.produit.increment!(:stock, vp.quantite)
      end

      remboursement = params[:remboursement]

      if @vente.espece.to_f > 0 || remboursement == "especes"
        MouvementEspece.create!(
          date: Date.today,
          sens: "sortie",
          montant: @vente.total_net,
          motif: "Remboursement vente annulée n°#{@vente.id} — #{params[:motif_annulation]}"
        )
      end

      if @vente.cb.to_f > 0 && params[:remboursement] == "especes"
        MouvementEspece.create!(
          date: Date.today,
          sens: "sortie",
          montant: @vente.total_net,
          motif: "Remboursement CB en espèces — vente n°#{@vente.id} — #{params[:motif_annulation]}"
        )
      end

      if params[:remboursement] == "aucun" && @vente.client.present?
        Avoir.create!(
          client: @vente.client,
          vente: @vente,
          montant: @vente.total_net,
          utilise: false,
          date: Date.today,
          remarques: "Annulation de la vente n°#{@vente.id}"
        )
      end

      if params[:remboursement] == "avoir"
        Avoir.create!(
          client: @vente.client,
          vente: @vente,
          montant: @vente.total_net,
          utilise: false,
          date: Date.today,
          remarques: "Annulation de la vente n°#{@vente.id}"
        )
      end

      redirect_to ventes_path, notice: "✅ Vente annulée avec succès. Les produits ont été remis en stock."
    end

    def recherche_produit
      code = correct_scanner_input(params[:code_barre])
      produit = Produit.find_by(code_barre: code)

      session[:ventes] ||= {}

      if produit
        produit.update(stock: 1) if produit.stock <= 0

        id_str = produit.id.to_s

        if session[:ventes][id_str].is_a?(Hash)
          session[:ventes][id_str]["quantite"] += 1
        else
          session[:ventes][id_str] = {
            "quantite" => 1,
            "prix" => (produit.en_promo? && produit.prix_promo.present? ? produit.prix_promo : produit.prix).to_d,
            "remise" => 0.to_d
          }
        end
      end

      @produits = Produit.find(session[:ventes].keys).index_by(&:id)
      @quantites = session[:ventes].transform_keys(&:to_i)

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to new_vente_path }
      end
    end

    def retirer_produit
      session[:ventes]&.delete(params[:produit_id].to_s)
      @produits = Produit.find(session[:ventes].keys).index_by(&:id)
      @quantites = session[:ventes].transform_keys(&:to_i)

      respond_to do |format|
        format.turbo_stream { render "recherche_produit" }
        format.html { redirect_to new_vente_path }
      end
    end

    def modifier_remise
      id = params[:produit_id].to_s
      remise = params[:remise].to_d

      session[:ventes] ||= {}

      # Sécurise le format
      if session[:ventes][id].is_a?(Integer)
        produit = Produit.find_by(id: id)
        session[:ventes][id] = {
          "quantite" => session[:ventes][id],
          "prix" => produit&.prix.to_d || 0.to_d,
          "remise" => 0.to_d
        }
      end

      session[:ventes][id]["remise"] = remise

      @produits = Produit.find(session[:ventes].keys).index_by(&:id)
      @quantites = session[:ventes].transform_keys(&:to_i).transform_values { |v| v["quantite"] }

      respond_to do |format|
        format.turbo_stream { render "recherche_produit" }
        format.html { redirect_to new_vente_path }
      end
    end

    def create
      session[:ventes] ||= {}
      ventes_data = session[:ventes]

      if ventes_data.empty?
        redirect_to new_vente_path, alert: "Aucun produit à encaisser."
        return
      end

      client = params[:sans_client] == "1" ? nil : Client.find_by(nom: params[:client_nom])

      total_brut = 0
      total_net  = 0
      ventes_produits = []

      ventes_data.each do |produit_id_str, infos|
        produit = Produit.find(produit_id_str)
        quantite = infos["quantite"].to_i
        prix_unitaire = infos["prix"].to_d
        remise_pct = infos["remise"].to_d

        total_ligne_brut = prix_unitaire * quantite
        remise_euros = (total_ligne_brut * (remise_pct / 100)).round(2)
        total_ligne_net = total_ligne_brut - remise_euros

        ventes_produits << {
          produit: produit,
          quantite: quantite,
          prix_unitaire: prix_unitaire,
          remise: remise_pct
        }

        total_brut += total_ligne_brut
        total_net  += total_ligne_net
      end

      # 🔄 Gestion de l’avoir
      reste_credit = nil
      avoir_utilise = nil
      montant_avoir = 0

      if params[:avoir_id].present?
        avoir_utilise = Avoir.find_by(id: params[:avoir_id], utilise: false)
        if avoir_utilise && (avoir_utilise.created_at >= 1.year.ago)
          montant_avoir = avoir_utilise.montant
          reste_a_payer = total_net - montant_avoir
          if reste_a_payer <= 0
            reste_credit = (montant_avoir - total_net).round(2)
            total_net = 0
            flash[:notice] ||= "✅ Vente à 0€ enregistrée via avoir."
          else
            total_net = reste_a_payer.round(2)
          end
        end
      end

      montants = {
        "CB" => params[:cb].to_d,
        "Espèces" => params[:espece].to_d,
        "Chèque" => params[:cheque].to_d,
        "AMEX" => params[:amex].to_d
      }

      # Ajout du montant de l’avoir utilisé (si présent)
      montant_avoir ||= 0

      # 💾 Création de la vente
      @vente = Caisse::Vente.new(
        client: client,
        date_vente: Time.current,
        total_brut: total_brut.round(2),
        total_net: total_net.round(2),
        cb: params[:cb].to_d,
        espece: params[:espece].to_d,
        cheque: params[:cheque].to_d,
        amex: params[:amex].to_d
      )

      ventes_produits.each { |vp| @vente.ventes_produits.build(vp) }

      if @vente.save
        @vente.ventes_produits.each do |vp|
          vp.produit.decrement!(:stock, vp.quantite)
        end

        if avoir_utilise
          avoir_utilise.update!(utilise: true, vente: @vente)
        end

        if reste_credit && reste_credit > 0
          Avoir.create!(
            client: avoir_utilise.client,
            vente: @vente,
            montant: reste_credit,
            utilise: false,
            date: Date.today,
            remarques: "Solde restant de l’avoir n°#{avoir_utilise.id}"
          )
        end

        session[:ventes] = {}
        redirect_to ventes_path, notice: "✅ Vente enregistrée avec succès."
      else
        redirect_to new_vente_path, alert: "❌ Erreur lors de l'enregistrement de la vente."
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
      vente = Caisse::Vente.find(params[:id])
      imprimer_ticket_texte(vente)
      redirect_to ventes_path, notice: "Ticket imprimé avec succès."
    end

    def export
      require "caxlsx_rails"

      mois = params[:mois] || (Date.today << 1).strftime("%Y-%m")

      date_debut = Date.parse("#{mois}-01")
      date_fin = date_debut.end_of_month.end_of_day

      ventes = Caisse::Vente.includes(ventes_produits: { produit: :client }, client: {}, versements: {}).where(date_vente: date_debut..date_fin)

      p = Axlsx::Package.new
      wb = p.workbook

      wb.add_worksheet(name: "Ventes #{mois}") do |sheet|
        sheet.add_row [
          "Date de vente", "Numéro de la vente", "Nom du produit", "Catégorie", "État",
          "Taux de TVA", "Prix d'achat", "Prix déposant", "Quantité", "Remise (€)", "Total déposant", "Prix vente TTC (net)", "Marge",
          "Nom de la déposante", "Date de versement", "Reçu", "Mode de paiement cliente", "Mode de versement déposante", 
          "Avoir utilisé n°", "Montant avoir utilisé", "Avoir émis n°", "Montant avoir émis"
        ]

        ventes.each do |vente|
          # Déduire le mode de paiement réel (multi)
          paiements = []
          paiements << "CB" if vente.cb.to_d > 0
          paiements << "Espèces" if vente.espece.to_d > 0
          paiements << "Chèque" if vente.cheque.to_d > 0
          paiements << "AMEX" if vente.amex.to_d > 0
          mode_paiement = paiements.join(" + ")

          vente.ventes_produits.each do |vp|
            produit = vp.produit
            quantite = vp.quantite
            prix_unit = vp.prix_unitaire
            prix_achat = produit.prix_achat
            prix_deposante = produit.prix_deposant || 0
            total_deposant = quantite * prix_deposante
            remise_pct = vp.remise.to_d
            total_brut = prix_unit * quantite
            remise_euros = (total_brut * remise_pct / 100).round(2)
            total_ttc = total_brut - remise_euros

            deposante = produit.client if produit.en_depot?
            versement = Versement.joins(:ventes).where(ventes: { id: vente.id }, client: deposante).first if deposante

            # TVA
            if produit.etat == "neuf"
              tva = (total_ttc / 1.2 * 0.2).round(2)
              taux_tva = "20%"
            else
              tva = 0
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

            # Infos déposante
            nom_deposante = deposante ? "#{deposante.prenom} #{deposante.nom}" : "N/A"
            date_versement = versement&.created_at&.strftime("%d/%m/%Y") || "N/A"
            numero_recu = versement&.numero_recu || "N/A"
            methode_versement = versement&.methode_paiement || "N/A"

            # Gestion des avoirs
            avoir_utilise = Avoir.find_by(vente_id: vente.id, utilise: true)
            avoir_emis = Avoir.where(vente_id: vente.id, utilise: false)
                              .where("remarques LIKE ?", "%Solde restant%").first

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
              avoir_utilise&.id || "",
              (avoir_utilise&.montant ? sprintf("%.2f", avoir_utilise.montant) : ""),
              avoir_emis&.id || "",
              (avoir_emis&.montant ? sprintf("%.2f", avoir_emis.montant) : "")
            ]
          end
        end
      end

      nom_fichier = "ventes_#{mois}.xlsx"
      send_data p.to_stream.read, filename: nom_fichier, type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    end


    private

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
        ventes_produits_attributes: [ :id, :produit_id, :code_barre, :quantite, :prix_unitaire, :_destroy ])
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
      lignes << "VINTAGE ROYAN".center(largeur)
      lignes << "3bis rue Notre Dame".center(largeur)
      lignes << "17200 Royan".center(largeur)
      lignes << "Tel: 0546778080".center(largeur)
      lignes << "-" * largeur
      lignes << "*** VENTE ***".center(largeur)
      lignes << "-" * largeur
      lignes << "Vente n°#{vente.id}"
      lignes << "Date : #{I18n.l(vente.date_vente || vente.created_at)}"
      lignes << "Client : #{vente.client&.nom || 'Sans cliente'}"
      lignes << "-" * largeur

      total_articles = 0

      vente.ventes_produits.includes(:produit).each do |vp|
        produit = vp.produit

        tva_str = produit.etat == "neuf" ? "TVA 20%" : "TVA 0%"
        ligne_info = "#{produit.categorie.capitalize} - #{produit.etat.capitalize} - #{tva_str}"
        lignes << ligne_info

        lignes << produit.nom[0..41] # une ligne max
        qte = vp.quantite
        pu = vp.prix_unitaire
        remise_pct = vp.remise.to_d rescue 0.to_d

        montant_brut = pu * qte
        remise_euros = (montant_brut * (remise_pct / 100)).round(2)
        montant_net = (montant_brut - remise_euros).round(2)

        lignes << "#{qte.to_s.rjust(10)} x #{format('%.2f €', pu)} => #{format('%.2f €', montant_brut).rjust(10)}"
        lignes << "- Remise : #{format('%.2f €', remise_euros)} (#{remise_pct.to_i}%)"
        lignes << "Total net : #{format('%.2f €', montant_net)}"
        lignes << "-" * largeur

        total_articles += qte
      end

      lignes << "-" * largeur
      lignes << "Total articles : #{total_articles}".rjust(largeur)

      # ✅ Calculs TVA / HT / TTC avec remises en %
      ttc_20 = vente.ventes_produits.select { |vp| vp.produit.etat == "neuf" }.sum do |vp|
        brut = vp.quantite * vp.prix_unitaire
        remise = brut * (vp.remise.to_d / 100)
        brut - remise
      end

      ht_20 = (ttc_20 / 1.2).round(2)
      tva_20 = (ttc_20 - ht_20).round(2)

      ttc_0 = vente.ventes_produits.reject { |vp| vp.produit.etat == "neuf" }.sum do |vp|
        brut = vp.quantite * vp.prix_unitaire
        remise = brut * (vp.remise.to_d / 100)
        brut - remise
      end

      ht_total = (ht_20 + ttc_0).round(2)
      tva_total = tva_20
      ttc_total = (ttc_0 + ttc_20).round(2)

      lignes << "-" * largeur
      lignes << "Sous-total HT".ljust(largeur - montant_col) + "#{'%.2f €' % ht_total}".rjust(montant_col)
      lignes << "TVA (20%)".ljust(largeur - montant_col) + "#{'%.2f €' % tva_total}".rjust(montant_col)
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

      # Reste à payer (toujours 0 sauf erreur de caisse)
      ttc_total = vente.total_net # ou recalcul selon ton besoin
      reste_a_payer = ttc_total - (somme_payee || 0)
      reste_a_payer = 0 if reste_a_payer.abs < 0.01
      lignes << "Reste à payer".ljust(largeur - montant_col) + "#{'%.2f €' % reste_a_payer}".rjust(montant_col)
      lignes << "-" * largeur

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
      lignes << "Horaires d'ouverture".center(largeur)
      lignes << "Lundi       14h30 - 19h00".center(largeur)
      lignes << "Mar -> Sam  10h00 - 19h00".center(largeur)
      lignes << "Dimanche    10h00 - 13h00".center(largeur)

      lignes << ""
      lignes << "Merci de votre visite".center(largeur)
      lignes << "A bientôt".center(largeur)
      lignes << "VINTAGE ROYAN".center(largeur)
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
      vente = Caisse::Vente.find(params[:id])

      file_to_print = encode_with_iconv(generer_ticket_texte(vente))
      system("lp", "-d", "SEWOO_LKT_Series", file_to_print.to_s)
    end
  end
end
