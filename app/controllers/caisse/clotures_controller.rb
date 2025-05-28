module Caisse
  # Contrôleur gérant les clôtures journalières et mensuelles de caisse.
  class CloturesController < ApplicationController
    require "ostruct"

    ##
    # Affiche la liste des clôtures, triées par date décroissante.
    def index
      @clotures = Caisse::Cloture.order(date: :desc)

      fond_initial = 0
      entrees = MouvementEspece.where(date: Date.today, sens: "entrée").sum(:montant)
      sorties = MouvementEspece.where(date: Date.today, sens: "sortie").sum(:montant)
      versements = Versement.where(methode_paiement: "Espèces", created_at: Date.today.all_day).sum(:montant)

      total_ventes_especes = Caisse::Vente.where(date_vente: Date.today.all_day, annulee: [false, nil]).sum(:espece)

      @fond_caisse_theorique = fond_initial + entrees - sorties - versements + total_ventes_especes
    end

    def refresh_fond_caisse
      fond_initial = 0
      entrees = MouvementEspece.where(date: Date.today, sens: "entrée").sum(:montant)
      sorties = MouvementEspece.where(date: Date.today, sens: "sortie").sum(:montant)
      versements = Versement.where(methode_paiement: "Espèces", created_at: Date.today.all_day).sum(:montant)

      total_ventes_especes = Caisse::Vente.where(date_vente: Date.today.all_day, annulee: [false, nil]).sum(:espece)

      @fond_caisse_theorique = fond_initial + entrees - sorties - versements + total_ventes_especes
      redirect_to clotures_path, notice: "✅ Fond de caisse théorique recalculé : #{sprintf('%.2f €', @fond_caisse_theorique)}"
    end

    ##
    # Affiche le détail d'une clôture journalière
    def show
      @cloture = Caisse::Cloture.find(params[:id])
      ventes = Caisse::Vente.includes(ventes_produits: :produit).where(date_vente: @cloture.date.all_day, annulee: [false, nil])
      
      @ventes_count = ventes.count
      @articles_count = ventes.sum { |v| v.ventes_produits.sum(&:quantite) }

      # Nouveaux totaux par mode de paiement (plus fiable)
      @total_cb      = ventes.sum(&:cb).to_d
      @total_amex    = ventes.sum(&:amex).to_d
      @total_especes = ventes.sum(&:espece).to_d
      @total_cheque  = ventes.sum(&:cheque).to_d

      @ttc_0 = 0
      @ttc_20 = 0
      @remises = 0

      ventes.each do |vente|
        vente.ventes_produits.each do |vp|
          montant = vp.prix_unitaire.to_f * vp.quantite
          remise  = (montant * vp.remise.to_f / 100.0).round(2)
          total_net = (montant - remise).round(2)

          @remises += remise
          if vp.produit.etat == "neuf"
            @ttc_20 += total_net
          else
            @ttc_0 += total_net
          end
        end
      end

      @ht_20   = (@ttc_20 / 1.2).round(2)
      @tva_20  = (@ttc_20 - @ht_20).round(2)
      @ht_0    = @ttc_0
      @tva_0   = 0
      @ht_total  = (@ht_0 + @ht_20).round(2)
      @tva_total = (@tva_0 + @tva_20).round(2)
      @ttc_total = (@ttc_0 + @ttc_20).round(2)
      @total_remises = @remises.round(2)
    end

    ##
    # Génère une clôture mensuelle à partir des clôtures journalières du mois donné,
    # puis imprime le ticket correspondant.
    def cloture_mensuelle
      mois = params[:mois]
      begin
        date = Date.parse("#{mois}-01")
      rescue ArgumentError
        redirect_to clotures_path, alert: "❌ Format de date invalide. Utilise AAAA-MM."
        return
      end

      if Caisse::Cloture.exists?(date: date.end_of_month, categorie: "mensuelle")
        redirect_to clotures_path, alert: "❌ Clôture mensuelle déjà enregistrée pour #{mois}."
        return
      end

      clotures_jour = Caisse::Cloture.where(categorie: "journalier", date: date.beginning_of_month..date.end_of_month)
      if clotures_jour.empty?
        redirect_to clotures_path, alert: "❌ Aucune clôture journalière trouvée pour ce mois."
        return
      end

      ventes_annulees_mois = Caisse::Vente.where(date_vente: date.beginning_of_month..date.end_of_month, annulee: true)
      total_annulations = ventes_annulees_mois.sum(&:total_net)

      total_versements = Versement
        .joins(:produits)
        .where(created_at: date.beginning_of_month..date.end_of_month)
        .sum("produits_versements.quantite * produits_versements.montant_unitaire")

      ventes_du_mois = Caisse::Vente.includes(ventes_produits: :produit)
        .where(date_vente: date.beginning_of_month..date.end_of_month, annulee: [false, nil])

      # Initialisation
      ttc_0 = ttc_20 = 0.to_d
      remises_globales_total = 0.to_d
      remises_produits_total = 0.to_d

      ventes_du_mois.each do |vente|
        remises_globales_total += vente.remise_globale.to_d if vente.respond_to?(:remise_globale)

        vente.ventes_produits.each do |vp|
          produit = vp.produit
          prix_unitaire = vp.prix_unitaire.to_d > 0 ? vp.prix_unitaire.to_d : vp.produit.prix.to_d
          quantite = vp.quantite
          remise_pct = vp.remise.to_d
          brut = prix_unitaire * quantite
          remise_euros = (brut * remise_pct / 100).round(2)
          remises_produits_total += remise_euros
          net = brut - remise_euros

          if vp.produit.etat == "neuf"
            ttc_20 += net
          else
            ttc_0 += net
          end
        end
      end

      # Répartition remise globale
      ttc_total_initial = ttc_0 + ttc_20
      if ttc_total_initial > 0 && remises_globales_total > 0
        coef = remises_globales_total / ttc_total_initial
        ttc_0_remise = (ttc_0 * coef).round(2)
        ttc_20_remise = (remises_globales_total - ttc_0_remise).round(2)
        ttc_0 -= ttc_0_remise
        ttc_20 -= ttc_20_remise
      end

      total_cb      = ventes_du_mois.sum(:cb).to_d
      total_amex    = ventes_du_mois.sum(:amex).to_d
      total_especes = ventes_du_mois.sum(:espece).to_d
      total_cheque  = ventes_du_mois.sum(:cheque).to_d
      total_articles = ventes_du_mois.sum { |v| v.ventes_produits.sum(&:quantite) }

      ht_20 = (ttc_20 / 1.2).round(2)
      tva_20 = (ttc_20 - ht_20).round(2)
      ht_0 = ttc_0
      total_ht = (ht_0 + ht_20).round(2)
      total_tva = tva_20
      total_ttc = (ttc_0 + ttc_20).round(2)

      cloture = Caisse::Cloture.create!(
        categorie: "mensuelle",
        date: date.end_of_month,
        total_ht: total_ht,
        total_tva: total_tva,
        total_ttc: total_ttc,
        total_versements: total_versements,
        total_cb: total_cb,
        total_amex: total_amex,
        total_especes: total_especes,
        total_cheque: total_cheque,
        total_encaisse: clotures_jour.sum(:total_encaisse),
        total_ventes: clotures_jour.sum(:total_ventes),
        total_clients: clotures_jour.sum(:total_clients),
        total_articles: total_articles,
        ticket_moyen: clotures_jour.average(:ticket_moyen).to_f.round(2),
        ht_0: ht_0,
        ht_20: ht_20,
        ttc_0: ttc_0,
        ttc_20: ttc_20,
        tva_20: tva_20,
        total_remises: (remises_produits_total + remises_globales_total).round(2),
        total_annulations: total_annulations
      )

      data = OpenStruct.new(
        categorie: "mensuelle",
        date: date.end_of_month,
        ouverture: date.beginning_of_month,
        total_ht: cloture.total_ht,
        total_tva: cloture.total_tva,
        total_ttc: cloture.total_ttc,
        total_versements: total_versements,
        total_cb: total_cb,
        total_amex: total_amex,
        total_especes: total_especes,
        total_cheque: total_cheque,
        total_encaisse: cloture.total_encaisse,
        total_ventes: cloture.total_ventes,
        total_clients: cloture.total_clients,
        total_articles: total_articles,
        ticket_moyen: cloture.ticket_moyen,
        ht_0: cloture.ht_0,
        ht_20: cloture.ht_20,
        ttc_0: cloture.ttc_0,
        ttc_20: cloture.ttc_20,
        tva_20: cloture.tva_20,
        total_remises: cloture.total_remises,
        total_annulations: total_annulations,
        details_ventes: [],
        details_annulations: ventes_annulees_mois.map do |vente|
          {
            numero_vente: vente.id,
            client: vente.client&.nom,
            heure: vente.date_vente.strftime("%H:%M"),
            total: vente.total_net,
            motif_annulation: vente.motif_annulation,
            produits: vente.ventes_produits.map { |vp|
              {
                nom: vp.produit.nom.truncate(25),
                quantite: vp.quantite,
                prix_unitaire: vp.prix_unitaire,
                remise: vp.remise
              }
            }
          }
        end,
        details_versements: []
      )

      path_utf8 = Rails.root.join("tmp", "z_ticket_mensuel.txt")
      path_cp   = Rails.root.join("tmp", "z_ticket_mensuel_cp858.txt")

      File.write(path_utf8, cloture_ticket_texte(data))
      system("iconv -f UTF-8 -t CP858 #{path_utf8} -o #{path_cp}")
      system("lp", "-d", "SEWOO_LKT_Series", "#{path_cp}")

      redirect_to clotures_path, notice: "✅ Clôture mensuelle de #{mois} enregistrée et imprimée."
    end

    ##
    # Imprime un ticket de clôture (mensuelle ou journalière)
    def imprimer
      cloture = Caisse::Cloture.find(params[:id])
      total_ventes = cloture.total_ventes
      jour = cloture.date
      ventes_annulees = Caisse::Vente.where(date_vente: jour.all_day, annulee: true)
      total_annulations = ventes_annulees.sum(&:total_net)
      total_versements = Versement
        .joins(:produits)
        .where(created_at: cloture.date.beginning_of_month..cloture.date.end_of_month)
        .sum("produits_versements.quantite * produits_versements.montant_unitaire")

      total_articles = if cloture.categorie == "mensuelle"
        Caisse::Vente.includes(ventes_produits: :produit)
             .where(date_vente: cloture.date.beginning_of_month..cloture.date.end_of_month, annulee: [false, nil])
             .sum { |v| v.ventes_produits.sum(&:quantite) }
      else
        Caisse::Vente.includes(ventes_produits: :produit)
             .where(date_vente: jour.all_day, annulee: [false, nil])
             .sum { |v| v.ventes_produits.sum(&:quantite) }
      end

      ventes = Caisse::Vente.includes(:client, ventes_produits: :produit).where(date_vente: jour.all_day, annulee: [false, nil])

      total_cb      = ventes.sum(:cb).to_d
      total_amex    = ventes.sum(:amex).to_d
      total_especes = ventes.sum do |vente|
        espece = vente.espece.to_d
        total_net = vente.total_net.to_d
        autres_paiements = vente.cb.to_d + vente.cheque.to_d + vente.amex.to_d

        rendu = [espece - (total_net - autres_paiements), 0].max
        espece - rendu
      end.round(2)

      total_cheque  = ventes.sum(:cheque).to_d
      total_encaisse = total_cb + total_amex + total_especes + total_cheque

      # Initialisation
      ht_0 = ttc_0 = ht_20 = ttc_20 = 0.to_d
      remises_produits_total = 0.to_d
      remises_globales_total = 0.to_d

      ventes.each do |vente|
        # Remise globale
        remise_globale = vente.respond_to?(:remise_globale) ? vente.remise_globale.to_d : 0
        remises_globales_total += remise_globale

        # Remises par produit et calculs TVA
        vente.ventes_produits.each do |vp|
          prix_unitaire = vp.prix_unitaire.to_d > 0 ? vp.prix_unitaire.to_d : vp.produit.prix.to_d
          quantite = vp.quantite
          remise_pct = vp.remise.to_d
          brut = prix_unitaire * quantite
          remise_euros = (brut * remise_pct / 100).round(2)
          remises_produits_total += remise_euros
          net = brut - remise_euros

          if vp.produit.etat == "neuf"
            ttc_20 += net
          else
            ttc_0 += net
          end
        end
      end

      # Répartition de la remise globale sur les produits
      ttc_total_initial = ttc_0 + ttc_20
      if ttc_total_initial > 0 && remises_globales_total > 0
        coef = remises_globales_total / ttc_total_initial
        ttc_0  -= (ttc_0 * coef).round(2)
        ttc_20 -= (ttc_20 * coef).round(2)
      end

      # Calcul HT / TVA
      ht_20 = (ttc_20 / 1.2).round(2)
      tva_20 = (ttc_20 - ht_20).round(2)
      ht_0 = ttc_0

      total_ht  = (ht_0 + ht_20).round(2)
      total_tva = tva_20
      total_ttc = ventes.sum(&:total_net).round(2)  # 💡 net inclut déjà les remises

      # Remises
      total_remises = (remises_produits_total + remises_globales_total).round(2)

      # Ticket moyen
      ticket_moyen = total_ventes.positive? ? (total_ttc / total_ventes).round(2) : 0

      fond_caisse_initial = cloture.fond_caisse_initial
      fond_caisse_final = cloture.fond_caisse_final

      data = OpenStruct.new(
        categorie: cloture.categorie,
        date: jour,
        ouverture: ventes.minimum(:created_at),
        total_ventes: cloture.total_ventes,
        total_clients: cloture.total_clients,
        total_articles: total_articles,
        ticket_moyen: ticket_moyen,
        total_cb: total_cb,
        total_amex: total_amex,
        total_cheque: total_cheque,
        total_especes: total_especes,
        total_encaisse: total_encaisse,
        ht_0: ht_0,
        ht_20: ht_20,
        ttc_0: ttc_0,
        ttc_20: ttc_20,
        tva_20: tva_20,
        total_ht: total_ht,
        total_tva: total_tva,
        total_ttc: total_ttc,
        total_remises: total_remises.round(2),
        total_annulations: total_annulations,
        fond_caisse_initial: fond_caisse_initial,
        fond_caisse_final: fond_caisse_final,
        total_versements: cloture.total_versements || 0,
        details_ventes: ventes.map do |vente|
          total_net = vente.total_net.to_d
          espece = vente.espece.to_d
          autres = vente.cb.to_d + vente.cheque.to_d + vente.amex.to_d
          rendu = [espece - (total_net - autres), 0].max

          {
            numero_vente: vente.id,
            heure: vente.date_vente.strftime("%H:%M"),
            paiement: "MULTI",
            multi: [
              { "mode" => "CB", "montant" => vente.cb.to_f },
              { "mode" => "Espèces", "montant" => espece },
              { "mode" => "Chèque", "montant" => vente.cheque.to_f },
              { "mode" => "AMEX", "montant" => vente.amex.to_f }
            ].reject { |p| p["montant"] <= 0 } + (rendu > 0 ? [{ "mode" => "Rendu", "montant" => rendu }] : []),
            remise_globale: vente.respond_to?(:remise_globale) ? vente.remise_globale.to_d : 0,
            produits: vente.ventes_produits.map do |vp|
              produit = vp.produit
              prix_unitaire = vp.prix_unitaire.to_f > 0 ? vp.prix_unitaire : produit.prix
              remise = vp.remise.to_f
              montant_total = (prix_unitaire * vp.quantite * (1 - remise / 100)).round(2)

              {
                nom: produit.nom.truncate(25),
                etat: produit.etat.capitalize,
                quantite: vp.quantite,
                prix_unitaire: prix_unitaire,
                remise: remise,
                montant_total: montant_total
              }
            end,
            total_vente: vente.total_net
          }
        end,
        details_annulations: ventes_annulees.map do |vente|
          {
            numero_vente: vente.id,
            client: vente.client&.nom,
            heure: vente.date_vente.strftime("%H:%M"),
            total: vente.total_net,
            motif_annulation: vente.motif_annulation,
            produits: vente.ventes_produits.map { |vp|
              {
                nom: vp.produit.nom.truncate(25),
                quantite: vp.quantite,
                prix_unitaire: vp.prix_unitaire,
                remise: vp.remise
              }
            }
          }
        end,
        details_versements: Versement.includes(client: {}, ventes: { ventes_produits: :produit })
          .where(created_at: jour.all_day)
          .map do |versement|
            produits = versement.ventes.flat_map(&:ventes_produits).map(&:produit)
            produits_client = produits.select { |p| p.client_id == versement.client_id }
            {
              heure: versement.created_at.strftime("%H:%M"),
              client: "#{versement.client.nom} #{versement.client.prenom}",
              montant: versement.montant,
              numero_recu: versement.numero_recu,
              produits: produits_client.group_by(&:id).map do |_, ps|
                produit = ps.first
                quantite = versement.ventes.sum do |vente|
                  vente.ventes_produits.where(produit_id: produit.id).sum(:quantite)
                end
                {
                  nom: produit.nom.truncate(25),
                  etat: produit.etat.capitalize,
                  quantite: quantite,
                  total: (quantite * produit.prix_deposant).round(2)
                }
              end
            }
          end
      )

      texte = cloture_ticket_texte(data)

      FileUtils.mkdir_p(Rails.root.join("tmp"))
      File.write(Rails.root.join("tmp/z_ticket.txt"), texte)
      system("iconv -f UTF-8 -t CP858 tmp/z_ticket.txt -o tmp/z_ticket_cp858.txt")
      system("lp", "-d", "SEWOO_LKT_Series", "tmp/z_ticket_cp858.txt")

      redirect_to clotures_path, notice: "✅ Clôture imprimée avec succès."
    end

    ##
    # Crée une clôture journalière (ticket Z) si elle n'existe pas déjà pour le jour donné
    def cloture_z
      jour = params[:date].present? ? Date.parse(params[:date]) : Date.current
      return redirect_to ventes_path, alert: "Clôture déjà effectuée pour aujourd’hui." if Caisse::Cloture.exists?(date: jour, categorie: "journalier")

      ventes = Caisse::Vente.includes(:client, ventes_produits: :produit).where(date_vente: jour.all_day, annulee: [false, nil])
      ventes_annulees = Caisse::Vente.where(date_vente: jour.all_day, annulee: true)
      total_annulations = ventes_annulees.sum(&:total_net)
      return redirect_to ventes_path, alert: "Aucune vente pour aujourd’hui." if ventes.empty?

      total_ventes = ventes.count
      total_clients = ventes.map(&:client_id).compact.uniq.size
      total_articles = ventes.sum { |v| v.ventes_produits.sum(&:quantite) }

      # ✅ Nouveau calcul des paiements sans JSON
      total_cb      = ventes.sum(:cb).to_d
      total_amex    = ventes.sum(:amex).to_d
      total_especes = ventes.sum do |vente|
        espece = vente.espece.to_d
        total_net = vente.total_net.to_d
        autres_paiements = vente.cb.to_d + vente.cheque.to_d + vente.amex.to_d

        rendu = [espece - (total_net - autres_paiements), 0].max
        espece - rendu
      end.round(2)

      total_cheque  = ventes.sum(:cheque).to_d

      total_encaisse = total_cb + total_amex + total_especes + total_cheque

      # Initialisation
      ht_0 = ttc_0 = ht_20 = ttc_20 = 0.to_d
      remises_produits_total = 0.to_d
      remises_globales_total = 0.to_d

      ventes.each do |vente|
        # Remise globale
        remise_globale = vente.respond_to?(:remise_globale) ? vente.remise_globale.to_d : 0
        remises_globales_total += remise_globale

        # Remises par produit et calculs TVA
        vente.ventes_produits.each do |vp|
          prix_unitaire = vp.prix_unitaire.to_d > 0 ? vp.prix_unitaire.to_d : vp.produit.prix.to_d
          quantite = vp.quantite
          remise_pct = vp.remise.to_d
          brut = prix_unitaire * quantite
          remise_euros = (brut * remise_pct / 100).round(2)
          remises_produits_total += remise_euros
          net = brut - remise_euros

          if vp.produit.etat == "neuf"
            ttc_20 += net
          else
            ttc_0 += net
          end
        end
      end

      # Répartition de la remise globale sur les produits
      ttc_total_initial = ttc_0 + ttc_20
      if ttc_total_initial > 0 && remises_globales_total > 0
        coef = remises_globales_total / ttc_total_initial
        ttc_0  -= (ttc_0 * coef).round(2)
        ttc_20 -= (ttc_20 * coef).round(2)
      end

      # Calcul HT / TVA
      ht_20 = (ttc_20 / 1.2).round(2)
      tva_20 = (ttc_20 - ht_20).round(2)
      ht_0 = ttc_0

      total_ht  = (ht_0 + ht_20).round(2)
      total_tva = tva_20
      total_ttc = ventes.sum(&:total_net).round(2)  # 💡 net inclut déjà les remises

      # Remises
      total_remises = (remises_produits_total + remises_globales_total).round(2)

      # Ticket moyen
      ticket_moyen = total_ventes.positive? ? (total_ttc / total_ventes).round(2) : 0

      fond_caisse_initial = 0
      fond_caisse_final = params[:fond_caisse_final].present? ? params[:fond_caisse_final].to_d : total_especes
      total_versements = Versement.where(created_at: jour.all_day).sum(:montant)

      Caisse::Cloture.create!(
        categorie: "journalier",
        date: jour,
        total_ht: total_ht,
        total_tva: total_tva,
        total_ttc: total_ttc,
        total_ventes: total_ventes,
        total_clients: total_clients,
        total_articles: total_articles,
        ticket_moyen: ticket_moyen,
        total_cb: total_cb,
        total_amex: total_amex,
        total_cheque: total_cheque,
        total_especes: total_especes,
        total_encaisse: total_encaisse,
        ht_0: ht_0,
        ht_20: ht_20,
        ttc_0: ttc_0,
        ttc_20: ttc_20,
        tva_20: tva_20,
        total_remises: total_remises.round(2),
        total_annulations: total_annulations,
        fond_caisse_initial: fond_caisse_initial,
        fond_caisse_final: fond_caisse_final,
        total_versements: total_versements
      )

      # ✅ Génère le ticket texte (non imprimé)
      data = OpenStruct.new(
        date: jour,
        ouverture: ventes.minimum(:created_at),
        total_ventes: total_ventes,
        total_clients: total_clients,
        total_articles: total_articles,
        ticket_moyen: ticket_moyen,
        total_cb: total_cb,
        total_amex: total_amex,
        total_cheque: total_cheque,
        total_especes: total_especes,
        total_encaisse: total_encaisse,
        ht_0: ht_0,
        ht_20: ht_20,
        ttc_0: ttc_0,
        ttc_20: ttc_20,
        tva_20: tva_20,
        total_ht: total_ht,
        total_tva: total_tva,
        total_ttc: total_ttc,
        total_remises: total_remises.round(2),
        total_annulations: total_annulations,
        fond_caisse_initial: fond_caisse_initial,
        fond_caisse_final: fond_caisse_final,
        total_versements: total_versements,
        details_ventes: ventes.map do |vente|
          total_net = vente.total_net.to_d
          espece = vente.espece.to_d
          autres = vente.cb.to_d + vente.cheque.to_d + vente.amex.to_d
          rendu = [espece - (total_net - autres), 0].max

          {
            numero_vente: vente.id,
            heure: vente.date_vente.strftime("%H:%M"),
            paiement: "MULTI",
            multi: [
              { "mode" => "CB", "montant" => vente.cb.to_f },
              { "mode" => "Espèces", "montant" => espece },
              { "mode" => "Chèque", "montant" => vente.cheque.to_f },
              { "mode" => "AMEX", "montant" => vente.amex.to_f }
            ].reject { |p| p["montant"] <= 0 } + (rendu > 0 ? [{ "mode" => "Rendu", "montant" => rendu }] : []),
            remise_globale: vente.respond_to?(:remise_globale) ? vente.remise_globale.to_d : 0,
            produits: vente.ventes_produits.map do |vp|
              produit = vp.produit
              prix_unitaire = vp.prix_unitaire.to_f > 0 ? vp.prix_unitaire : produit.prix
              remise = vp.remise.to_f
              montant_total = (prix_unitaire * vp.quantite * (1 - remise / 100)).round(2)

              {
                nom: produit.nom.truncate(25),
                etat: produit.etat.capitalize,
                quantite: vp.quantite,
                prix_unitaire: prix_unitaire,
                remise: remise,
                montant_total: montant_total
              }
            end,
            total_vente: vente.total_net
          }
        end,
        details_annulations: ventes_annulees.map do |vente|
          {
            numero_vente: vente.id,
            client: vente.client&.nom,
            heure: vente.date_vente.strftime("%H:%M"),
            total: vente.total_net,
            motif_annulation: vente.motif_annulation,
            produits: vente.ventes_produits.map { |vp|
              {
                nom: vp.produit.nom.truncate(25),
                quantite: vp.quantite,
                prix_unitaire: vp.prix_unitaire,
                remise: vp.remise
              }
            }
          }
        end,
        details_versements: Versement.includes(client: {}, ventes: { ventes_produits: :produit })
          .where(created_at: jour.all_day)
          .map do |versement|
            produits = versement.ventes.flat_map(&:ventes_produits).map(&:produit)
            produits_client = produits.select { |p| p.client_id == versement.client_id }
            {
              heure: versement.created_at.strftime("%H:%M"),
              client: "#{versement.client.nom} #{versement.client.prenom}",
              montant: versement.montant,
              numero_recu: versement.numero_recu,
              produits: produits_client.group_by(&:id).map do |_, ps|
                produit = ps.first
                quantite = versement.ventes.sum do |vente|
                  vente.ventes_produits.where(produit_id: produit.id).sum(:quantite)
                end
                {
                  nom: produit.nom.truncate(25),
                  etat: produit.etat.capitalize,
                  quantite: quantite,
                  total: (quantite * produit.prix_deposant).round(2)
                }
              end
            }
          end
      )

      texte = cloture_ticket_texte(data)
      # Impression désactivée pour l’instant :
      # File.write(Rails.root.join("tmp/z_ticket.txt"), texte)
      # system("iconv -f UTF-8 -t CP858 tmp/z_ticket.txt -o tmp/z_ticket_cp858.txt")
      # system("lp", "-d", "SEWOO_LKT_Series", "tmp/z_ticket_cp858.txt")

      redirect_to clotures_path, notice: "✅ Clôture générée sans impression automatique."
    end

    ##
    # Prévisualisation de la clôture avec tous les détails
    def preview
      cloture = Caisse::Cloture.find(params[:id])
      jour = cloture.date

      plage = cloture.categorie == "mensuelle" ? jour.beginning_of_month..jour.end_of_month : jour.all_day

      ventes = Caisse::Vente.includes(:client, ventes_produits: :produit).where(date_vente: plage, annulee: [false, nil])
      ventes_annulees = Caisse::Vente.where(date_vente: plage, annulee: true)
      total_annulations = ventes_annulees.sum(&:total_net)

      total_ventes = ventes.count
      total_clients = ventes.map(&:client_id).compact.uniq.size
      total_articles = ventes.sum { |v| v.ventes_produits.sum(&:quantite) }

      total_cb      = ventes.sum(:cb).to_d
      total_amex    = ventes.sum(:amex).to_d
      total_especes = ventes.sum do |vente|
        espece = vente.espece.to_d
        total_net = vente.total_net.to_d
        autres_paiements = vente.cb.to_d + vente.cheque.to_d + vente.amex.to_d

        rendu = [espece - (total_net - autres_paiements), 0].max
        espece - rendu
      end.round(2)

      total_cheque  = ventes.sum(:cheque).to_d
      total_encaisse = total_cb + total_amex + total_especes + total_cheque

      # Initialisation
      ht_0 = ttc_0 = ht_20 = ttc_20 = 0.to_d
      remises_produits_total = 0.to_d
      remises_globales_total = 0.to_d

      ventes.each do |vente|
        # Remise globale
        remise_globale = vente.respond_to?(:remise_globale) ? vente.remise_globale.to_d : 0
        remises_globales_total += remise_globale

        # Remises par produit et calculs TVA
        vente.ventes_produits.each do |vp|
          prix_unitaire = vp.prix_unitaire.to_d > 0 ? vp.prix_unitaire.to_d : vp.produit.prix.to_d
          quantite = vp.quantite
          remise_pct = vp.remise.to_d
          brut = prix_unitaire * quantite
          remise_euros = (brut * remise_pct / 100).round(2)
          remises_produits_total += remise_euros
          net = brut - remise_euros

          if vp.produit.etat == "neuf"
            ttc_20 += net
          else
            ttc_0 += net
          end
        end
      end

      # Répartition de la remise globale sur les produits
      ttc_total_initial = ttc_0 + ttc_20
      if ttc_total_initial > 0 && remises_globales_total > 0
        coef = remises_globales_total / ttc_total_initial
        ttc_0  -= (ttc_0 * coef).round(2)
        ttc_20 -= (ttc_20 * coef).round(2)
      end

      # Calcul HT / TVA
      ht_20 = (ttc_20 / 1.2).round(2)
      tva_20 = (ttc_20 - ht_20).round(2)
      ht_0 = ttc_0

      total_ht  = (ht_0 + ht_20).round(2)
      total_tva = tva_20
      total_ttc = ventes.sum(&:total_net).round(2)  # 💡 net inclut déjà les remises

      # Remises
      total_remises = (remises_produits_total + remises_globales_total).round(2)

      # Ticket moyen
      ticket_moyen = total_ventes.positive? ? (total_ttc / total_ventes).round(2) : 0

      fond_caisse_initial = cloture.fond_caisse_initial
      fond_caisse_final = cloture.fond_caisse_final
      total_versements = cloture.total_versements

      data = OpenStruct.new(
        categorie: cloture.categorie,
        date: jour,
        ouverture: ventes.minimum(:created_at),
        total_ventes: total_ventes,
        total_clients: total_clients,
        total_articles: total_articles,
        ticket_moyen: ticket_moyen,
        total_cb: total_cb,
        total_amex: total_amex,
        total_cheque: total_cheque,
        total_especes: total_especes,
        total_encaisse: total_encaisse,
        ht_0: ht_0,
        ht_20: ht_20,
        ttc_0: ttc_0,
        ttc_20: ttc_20,
        tva_20: tva_20,
        total_ht: total_ht,
        total_tva: total_tva,
        total_ttc: total_ttc,
        total_remises: total_remises.round(2),
        total_annulations: total_annulations,
        fond_caisse_initial: fond_caisse_initial,
        fond_caisse_final: fond_caisse_final,
        total_versements: total_versements,
        details_ventes: ventes.map do |vente|
          total_net = vente.total_net.to_d
          espece = vente.espece.to_d
          autres = vente.cb.to_d + vente.cheque.to_d + vente.amex.to_d
          rendu = [espece - (total_net - autres), 0].max

          {
            numero_vente: vente.id,
            heure: vente.date_vente.strftime("%H:%M"),
            paiement: "MULTI",
            multi: [
              { "mode" => "CB", "montant" => vente.cb.to_f },
              { "mode" => "Espèces", "montant" => espece },
              { "mode" => "Chèque", "montant" => vente.cheque.to_f },
              { "mode" => "AMEX", "montant" => vente.amex.to_f }
            ].reject { |p| p["montant"] <= 0 } + (rendu > 0 ? [{ "mode" => "Rendu", "montant" => rendu }] : []),
            remise_globale: vente.respond_to?(:remise_globale) ? vente.remise_globale.to_d : 0,
            produits: vente.ventes_produits.map do |vp|
              produit = vp.produit
              prix_unitaire = vp.prix_unitaire.to_f > 0 ? vp.prix_unitaire : produit.prix
              remise = vp.remise.to_f
              montant_total = (prix_unitaire * vp.quantite * (1 - remise / 100)).round(2)

              {
                nom: produit.nom.truncate(25),
                etat: produit.etat.capitalize,
                quantite: vp.quantite,
                prix_unitaire: prix_unitaire,
                remise: remise,
                montant_total: montant_total
              }
            end,
            total_vente: vente.total_net
          }
        end,
        details_annulations: ventes_annulees.map do |vente|
          {
            numero_vente: vente.id,
            client: vente.client&.nom,
            heure: vente.date_vente.strftime("%H:%M"),
            total: vente.total_net,
            motif_annulation: vente.motif_annulation,
            produits: vente.ventes_produits.map { |vp|
              {
                nom: vp.produit.nom.truncate(25),
                quantite: vp.quantite,
                prix_unitaire: vp.prix_unitaire,
                remise: vp.remise
              }
            }
          }
        end,
        details_versements: Versement.includes(client: {}, ventes: { ventes_produits: :produit })
          .where(created_at: plage)
          .map do |versement|
            produits = versement.ventes.flat_map(&:ventes_produits).map(&:produit)
            produits_client = produits.select { |p| p.client_id == versement.client_id }
            {
              heure: versement.created_at.strftime("%H:%M"),
              client: "#{versement.client.nom} #{versement.client.prenom}",
              montant: versement.montant,
              numero_recu: versement.numero_recu,
              produits: produits_client.group_by(&:id).map do |_, ps|
                produit = ps.first
                quantite = versement.ventes.sum do |vente|
                  vente.ventes_produits.where(produit_id: produit.id).sum(:quantite)
                end
                {
                  nom: produit.nom.truncate(25),
                  etat: produit.etat.capitalize,
                  quantite: quantite,
                  total: (quantite * produit.prix_deposant).round(2)
                }
              end
            }
          end
      )

      @ticket_z = cloture_ticket_texte(data)
    end


    private

    ##
    # Génère le contenu texte du ticket de clôture à imprimer (Z ou mensuelle).
    def cloture_ticket_texte(data)
      largeur = 42
      lignes = []
      lignes << "VINTAGE ROYAN".center(largeur)
      lignes << "3bis rue Notre-Dame".center(largeur)
      lignes << "17200 Royan".center(largeur)
      lignes << "SIRET : 832 259 837 00031".center(largeur)
      titre = data.categorie == "mensuelle" ? "Clôture mensuelle" : "Clôture de caisse Z"
      lignes << titre.center(largeur)
      lignes << I18n.l(data.date, format: :long).center(largeur)
      lignes << "-" * largeur

      # 2️⃣ Dates
      lignes << "Ouverture : #{I18n.l(data.ouverture || data.date.beginning_of_day, format: :long)}"
      lignes << "Clôture   : #{I18n.l(data.date, format: :long)} à 20:00"
      lignes << "-" * largeur

      # 3️⃣ Statistiques générales
      lignes << "STATISTIQUES"
      lignes << "Nombre de ventes           : #{data.total_ventes.to_i}"
      lignes << "Nombre d'article vendu     : #{data.total_articles.to_i}"
      lignes << "Nombre de nouveaux clients : #{data.total_clients.to_i}"
      lignes << "Ticket moyen               : #{format('%.2f €', data.ticket_moyen)}"
      lignes << "-" * largeur

      # 4️⃣ Paiements
      lignes << "PAIEMENTS"
      lignes << "AMEX           : #{format('%.2f €', data.total_amex)}"
      lignes << "CB             : #{format('%.2f €', data.total_cb)}"
      lignes << "Espèces        : #{format('%.2f €', data.total_especes)}"
      lignes << "Chèque         : #{format('%.2f €', data.total_cheque)}"
      lignes << "Total encaissé : #{format('%.2f €', data.total_encaisse)}"
      lignes << "-" * largeur

      # 5️⃣ TVA
      lignes << "RECAPITULATIF TVA"
      lignes << format("%-8s%-10s%-10s%-10s", "Taux", "HT", "TVA", "TTC")
      lignes << format("%-8s%-10s%-10s%-10s", "0%", format("%.2f €", data.ht_0), "0.00 €", format("%.2f €", data.ttc_0))
      lignes << format("%-8s%-10s%-10s%-10s", "20%", format("%.2f €", data.ht_20), format("%.2f €", data.tva_20), format("%.2f €", data.ttc_20))
      lignes << "-" * largeur

      # 6️⃣ Totaux
      lignes << "CHIFFRE D'AFFAIRES"
      lignes << format("Total HT   : %.2f €", data.total_ht)
      lignes << format("Total TVA  : %.2f €", data.total_tva)
      lignes << format("Total TTC  : %.2f €", data.total_ttc)
      lignes << "-" * largeur

      # 7️⃣ Divers
      lignes << "REMISES ET ANNULATIONS"
      lignes << "Total remises         : #{format('%.2f €', data.total_remises)}"
      lignes << "Total annulations     : #{format('%.2f €', data.total_annulations)}"
      lignes << "-" * largeur

      lignes << "VENTES ANNULÉES"
      if data.details_annulations.present? && data.details_annulations.any?
        data.details_annulations.each do |annulation|
          client = annulation[:client].to_s
          heure = annulation[:heure].to_s
          total = annulation[:total] || 0
          motif = annulation[:motif_annulation].to_s.strip

          # Remplacer les tirets longs par un simple tiret ASCII
          lignes << "N°#{annulation[:numero_vente]} - #{client} - #{heure} - Total : #{sprintf('%.2f', total)}€"

          if motif.present?
            lignes << "Motif : #{motif}"
          end

          (annulation[:produits] || []).each do |prod|
            nom = prod[:nom].to_s
            quantite = prod[:quantite] || 0
            prix_unitaire = prod[:prix_unitaire] || 0
            remise = prod[:remise] || 0
            lignes << "   #{nom} x#{quantite} à #{sprintf('%.2f', prix_unitaire)}€ (remise #{remise}%)"
          end
        end
      else
        lignes << "(aucune vente annulée)"
      end
      lignes << "-" * largeur

      unless data.categorie == "mensuelle"
        total_ventes_especes = Vente.where(date_vente: data.date.all_day, annulee: [false, nil]).sum(:espece).to_f
        fond_theorique = data.fond_caisse_initial.to_f +
          MouvementEspece.where(date: data.date, sens: "entrée").sum(:montant).to_f -
          MouvementEspece.where(date: data.date, sens: "sortie").sum(:montant).to_f -
          data.total_versements.to_f +
          total_ventes_especes
        difference = data.fond_caisse_final.to_f - fond_theorique
        lignes << "FOND DE CAISSE"
        lignes << "Initial        : #{format('%.2f €', data.fond_caisse_initial.to_f)}"
        lignes << "Théorique     : #{format('%.2f €', fond_theorique)}"
        lignes << "Final (compté) : #{format('%.2f €', data.fond_caisse_final.to_f)}"
        lignes << "Différence     : #{format('%+.2f €', difference)}"
        lignes << "-" * largeur
      end

      # Versements
      lignes << "VERSEMENTS AUX DEPOSANTS"
      lignes << ""
      lignes << "Total versé : #{format('%.2f €', data.total_versements.to_f)}"
      lignes << "-" * largeur

      # 8️⃣ Détail des ventes
      # On suppose que data.details_ventes est un tableau de lignes avec :numero_vente
      ventes_groupes = data.details_ventes.group_by { |ligne| ligne[:numero_vente] }

      lignes << "DETAIL DES VENTES"
      lignes << ""

      data.details_ventes.each do |vente|
        lignes << "Vente n°#{vente[:numero_vente]} - #{vente[:heure]} - multi-paiement :"
        vente[:multi].each do |p|
          lignes << "  - #{p['mode']} : #{'%.2f €' % p['montant']}"
        end

        vente[:produits].each do |prod|
          lignes << "  #{prod[:nom]}"
          lignes << "    #{prod[:etat]} - x#{prod[:quantite]} à #{'%.2f €' % prod[:prix_unitaire]}"
          if prod[:remise].to_f > 0
            remise_euros = (prod[:prix_unitaire] * prod[:quantite] * (prod[:remise].to_f / 100)).round(2)
            lignes << "    Remise : -#{'%.2f €' % remise_euros} (#{prod[:remise].to_i} %)"
          end
          lignes << "    Total : #{'%.2f €' % prod[:montant_total]}"
        end

        if vente[:remise_globale].to_f > 0
          lignes << "    Remise globale : -#{'%.2f €' % vente[:remise_globale]}"
        end

        lignes << "  -> Total vente : #{'%.2f €' % vente[:total_vente]}"
        lignes << "-" * 42
      end

      # 9️⃣ Détail des versements
      lignes << "DETAIL DES VERSEMENTS"
      lignes << ""
      data.details_versements.each do |v|
        lignes << "#{v[:heure]} - Reçu: #{v[:numero_recu]}"
        lignes << "#{v[:client]}"
        lignes << "Montant : #{format('%.2f €', v[:montant])}"
        lignes << "Produits de la déposante :"
        v[:produits].each do |p|
          ligne_produit = "  - #{p[:nom].ljust(18)} x#{p[:quantite].to_s.ljust(2)} = #{format('%.2f €', p[:total])}"
          lignes << ligne_produit
        end
        lignes << ""
      end
      lignes << "-" * largeur

      # 10 Clôture
      lignes << ""
      lignes << "Merci et à demain !".center(largeur)
      lignes << "\n" * 10
      lignes.join("\n")
    end
  end
end