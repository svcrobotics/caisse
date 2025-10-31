module Caisse
  # Contrôleur gérant les clôtures journalières et mensuelles de caisse.
  class CloturesController < ApplicationController
    require "ostruct"

    ##
    # Affiche la liste des clôtures, triées par date décroissante.
    def index
      @clotures = Caisse::Cloture.order(date: :desc)

      fond_initial = 0.to_d
      entrees  = MouvementEspece.where(date: Date.today, sens: "entrée").sum(:montant)
      sorties  = MouvementEspece.where(date: Date.today, sens: "sortie").sum(:montant)
      versements = Versement.where(methode_paiement: "Espèces", created_at: Date.today.all_day).sum(:montant)

      total_ventes_especes = Caisse::Vente
                                .where(date_vente: Date.today.all_day, annulee: [false, nil])
                                .sum(:espece)

      @fond_caisse_theorique = fond_initial + entrees - sorties - versements
    end

    def refresh_fond_caisse
      fond_initial = 0.to_d
      entrees  = MouvementEspece.where(date: Date.today, sens: "entrée").sum(:montant)
      sorties  = MouvementEspece.where(date: Date.today, sens: "sortie").sum(:montant)
      versements = Versement.where(methode_paiement: "Espèces", created_at: Date.today.all_day).sum(:montant)

      total_ventes_especes = Caisse::Vente
                                .where(date_vente: Date.today.all_day, annulee: [false, nil])
                                .sum(:espece)

      @fond_caisse_theorique = fond_initial + entrees - sorties - versements
      redirect_to clotures_path, notice: "✅ Fond de caisse théorique recalculé : #{sprintf('%.2f €', @fond_caisse_theorique)}"
    end

    ##
    # Affiche le détail d'une clôture journalière
    def show
      @cloture = Caisse::Cloture.find(params[:id])
      ventes   = Caisse::Vente
                   .includes(ventes_produits: :produit)
                   .where(date_vente: @cloture.date.all_day, annulee: [false, nil])

      @ventes_count   = ventes.count
      @articles_count = ventes.sum { |v| v.ventes_produits.sum(&:quantite) }

      # Totaux par mode de paiement (une seule fois par vente)
      # @total_cb      = ventes.sum(:cb).to_d
      # @total_amex    = ventes.sum(:amex).to_d
      @total_especes = ventes.sum do |v|
        e      = v.espece.to_d
        autres = v.cb.to_d + v.cheque.to_d + v.amex.to_d
        rendu  = [e - (v.total_net.to_d - autres), 0].max
        (e - rendu).round(2)
      end.round(2)
      # @total_cheque  = ventes.sum(:cheque).to_d

      base = Caisse::Vente.where(id: ventes.select(:id)) # retire l'effet du includes/join

      total_cb     = base.sum(:cb).to_d
      total_amex   = base.sum(:amex).to_d
      total_cheque = base.sum(:cheque).to_d


      # Calcul des remises et ventilation TVA
      @ttc_0      = 0.to_d
      @ttc_20     = 0.to_d
      @remises    = 0.to_d

      ventes.each do |v|
        v.ventes_produits.each do |vp|
          montant = vp.prix_unitaire.to_d * vp.quantite
          remise_produit = (montant * (vp.remise.to_d / 100)).round(2)
          total_net_ligne = (montant - remise_produit).round(2)

          @remises += remise_produit
          if vp.produit.etat == "neuf"
            @ttc_20 += total_net_ligne
          else
            @ttc_0 += total_net_ligne
          end
        end
      end

      @ht_20    = (@ttc_20 / 1.2).round(2)
      @tva_20   = (@ttc_20 - @ht_20).round(2)
      @ht_0     = @ttc_0
      @tva_0    = 0.to_d
      @ht_total   = (@ht_0 + @ht_20).round(2)
      @tva_total  = (@tva_0 + @tva_20).round(2)
      @ttc_total  = (@ttc_0 + @ttc_20).round(2)
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

      # On regarde si une clôture mensuelle existe déjà
      if Caisse::Cloture.exists?(date: date.end_of_month, categorie: "mensuelle")
        redirect_to clotures_path, alert: "❌ Clôture mensuelle déjà enregistrée pour #{mois}."
        return
      end

      # Plage complète (date_time) du mois
      debut_mois = date.beginning_of_month.beginning_of_day
      fin_mois   = date.end_of_month.end_of_day

      # Récupère les clôtures journalières (Z) de ce mois
      clotures_jour = Caisse::Cloture.where(
        categorie: "journalier",
        date: date.beginning_of_month..date.end_of_month
      )
      if clotures_jour.empty?
        redirect_to clotures_path, alert: "❌ Aucune clôture journalière trouvée pour ce mois."
        return
      end

      # On récupère TOUTES les ventes (non annulées) sur la plage horaire complète
      ventes_du_mois = Caisse::Vente
                         .includes(ventes_produits: :produit)
                         .where(date_vente: debut_mois..fin_mois, annulee: [false, nil])

      # Et on récupère toutes les ventes annulées pour le mois
      ventes_annulees_mois = Caisse::Vente.where(
        date_vente: debut_mois..fin_mois,
        annulee: true
      )
      total_annulations = ventes_annulees_mois.sum(&:total_net)

      # #️⃣ Calcul HT/TVA et remises produits (20% vs 0%)
      ttc_0                  = 0.to_d
      ttc_20                 = 0.to_d
      remises_produits_total = 0.to_d
      remises_globales_total = 0.to_d

      # Parcours des ventes du mois pour cumuler HT/TVA ligne par ligne (même algorithme que cloture_z)
      ventes_du_mois.each do |v|
        # 1) On récupère la remise globale de cette vente
        remise_globale = v.respond_to?(:remise_globale) ? v.remise_globale.to_d : 0.to_d
        remises_globales_total += remise_globale

        # montant servant à répartir la remise globale en prorata sur chaque ligne
        total_net_sans_remise_globale = v.total_net.to_d + remise_globale

        v.ventes_produits.each do |vp|
          produit       = vp.produit
          quantite      = vp.quantite
          # prix unitaire : on utilise vp.prix_unitaire > 0 si renseigné, sinon prix catalogue
          prix_unitaire = vp.prix_unitaire.to_d.positive? ? vp.prix_unitaire.to_d : produit.prix.to_d

          # Calcul du brut et de la remise “produit”
          brut          = prix_unitaire * quantite
          remise_euros  = (brut * (vp.remise.to_d / 100.0)).round(2)
          remises_produits_total += remise_euros
          net_apres_prod = (brut - remise_euros).round(2)

          # Répartition de la remise globale au prorata du “net_apres_prod”
          part_remise_globale = if total_net_sans_remise_globale.positive?
            (net_apres_prod / total_net_sans_remise_globale * remise_globale).round(2)
          else
            0.to_d
          end

          net_final = (net_apres_prod - part_remise_globale).round(2)

          # Selon l’état du produit, on va dans ttc_20 (neuf) ou ttc_0 (occasion)
          if produit.etat == "neuf"
            ttc_20 += net_final
          else
            ttc_0  += net_final
          end
        end
      end

      # À ce stade, ttc_20 et ttc_0 ont déjà subi, pour chaque ligne, 
      # la déduction des remises produit + quote-part de remise globale.
      # On peut donc calculer HT/TVA de la même façon que pour la journalière :

      ht_20 = (ttc_20 / 1.2).round(2)
      tva_20 = (ttc_20 - ht_20).round(2)
      ht_0  = ttc_0


      # Montants par mode de paiement (uniquement sur les ventes non annulées)
      # total_cb      = ventes_du_mois.sum(:cb).to_d
      # total_amex    = ventes_du_mois.sum(:amex).to_d
      total_especes = ventes_du_mois.sum(:espece).to_d
      # total_cheque  = ventes_du_mois.sum(:cheque).to_d

      base = Caisse::Vente.where(id: ventes_du_mois.select(:id))

      total_cb     = base.sum(:cb).to_d
      total_amex   = base.sum(:amex).to_d
      total_cheque = base.sum(:cheque).to_d


      # Nombre total d'articles vendus
      total_articles = ventes_du_mois.sum { |v| v.ventes_produits.sum(&:quantite) }

      # Calcul HT/TVA
      ht_20   = (ttc_20 / 1.2).round(2)
      tva_20  = (ttc_20 - ht_20).round(2)
      ht_0    = ttc_0
      total_ht  = (ht_0 + ht_20).round(2)
      total_tva = tva_20
      total_ttc = (ttc_0 + ttc_20).round(2)

      # Versements du mois (en utilisant l’intervalle horaire complet)
      total_versements = Versement
                           .joins(:produits)
                           .where(created_at: debut_mois..fin_mois)
                           .sum("produits_versements.quantite * produits_versements.montant_unitaire")

      # Remboursements « avoir » sur le mois (produit déjà retourné par Avoir)
      remboursements_du_jour = Avoir
                                 .where(date: debut_mois..fin_mois)
                                 .where("motif LIKE ?", "Remboursement produit%")
      total_rembourses = remboursements_du_jour.sum(:montant)

      total_ttc_apres_remboursements = total_ttc - total_rembourses

      # SI VOUS SOUHAITEZ VOUS APPUYER SUR LES Z JOURNALIÈRES :
      # total_ventes  = clotures_jour.sum(:total_ventes)
      # total_clients = clotures_jour.sum(:total_clients)
      # total_encaisse = clotures_jour.sum(:total_encaisse)
      # ticket_moyen  = clotures_jour.average(:ticket_moyen).to_f.round(2)

      # … OU, SI VOUS VOULEZ CALCULER DIRECTEMENT :
      total_ventes  = ventes_du_mois.count
      total_clients = ventes_du_mois.map(&:client_id).compact.uniq.size
      total_encaisse = total_cb + total_amex + total_especes + total_cheque
      ticket_moyen  = total_ventes.positive? ? (ventes_du_mois.sum(&:total_net) / total_ventes).round(2) : 0

      # Création de la clôture mensuelle en base
      cloture = Caisse::Cloture.create!(
        categorie:           "mensuelle",
        date:                date.end_of_month,
        total_ht:            total_ht,
        total_tva:           total_tva,
        total_ttc:           total_ttc,
        total_versements:    total_versements,
        total_cb:            total_cb,
        total_amex:          total_amex,
        total_especes:       total_especes,
        total_cheque:        total_cheque,
        total_encaisse:      total_encaisse,
        total_ventes:        total_ventes,
        total_clients:       total_clients,
        total_articles:      total_articles,
        ticket_moyen:        ticket_moyen,
        ht_0:                ht_0,
        ht_20:               ht_20,
        ttc_0:               ttc_0,
        ttc_20:              ttc_20,
        tva_20:              tva_20,
        total_remises:       (remises_produits_total + remises_globales_total).round(2),
        total_annulations:   total_annulations
      )

      # Préparation des données pour le ticket d’impression
      data = OpenStruct.new(
        categorie:         "mensuelle",
        date:              date.end_of_month,
        ouverture:         date.beginning_of_month.beginning_of_day,  # début du mois
        total_ht:          cloture.total_ht,
        total_tva:         cloture.total_tva,
        total_ttc:         cloture.total_ttc,
        total_versements:  total_versements,
        total_cb:          total_cb,
        total_amex:        total_amex,
        total_especes:     total_especes,
        total_cheque:      total_cheque,
        total_encaisse:    cloture.total_encaisse,
        total_ventes:      cloture.total_ventes,
        total_clients:     cloture.total_clients,
        total_articles:    total_articles,
        ticket_moyen:      cloture.ticket_moyen,
        ht_0:              cloture.ht_0,
        ht_20:             cloture.ht_20,
        ttc_0:             cloture.ttc_0,
        ttc_20:            cloture.ttc_20,
        tva_20:            cloture.tva_20,
        total_remises:     cloture.total_remises,
        total_annulations: total_annulations,
        total_rembourses:  total_rembourses,
        total_ttc_apres_remboursements: total_ttc_apres_remboursements,

        # On laisse éventuellement vide la partie détail mensuel…
        details_ventes:    [],

        details_annulations: ventes_annulees_mois.map do |v|
          {
            numero_vente:     v.id,
            client:           v.client&.nom,
            heure:            v.date_vente.strftime("%H:%M"),
            total:            v.total_net,
            motif_annulation: v.motif_annulation,
            produits:         v.ventes_produits.map do |vp|
              {
                nom:           vp.produit.nom.truncate(25),
                quantite:      vp.quantite,
                prix_unitaire: vp.prix_unitaire,
                remise:        vp.remise
              }
            end
          }
        end,

        details_versements: []
      )

      # Écriture du ticket texte et envoi à l'imprimante
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
      jour    = cloture.date
      total_ventes = cloture.total_ventes

      ventes_annulees = Caisse::Vente.where(date_vente: jour.all_day, annulee: true)
      total_annulations = ventes_annulees.sum(&:total_net)

      total_versements = Versement
                           .joins(:produits)
                           .where(created_at: cloture.date.beginning_of_month..cloture.date.end_of_month)
                           .sum("produits_versements.quantite * produits_versements.montant_unitaire")

      total_articles = if cloture.categorie == "mensuelle"
        Caisse::Vente
          .includes(ventes_produits: :produit)
          .where(
            date_vente: cloture.date.beginning_of_month..cloture.date.end_of_month,
            annulee: [false, nil]
          )
          .sum { |v| v.ventes_produits.sum(&:quantite) }
      else
        Caisse::Vente
          .includes(ventes_produits: :produit)
          .where(date_vente: jour.all_day, annulee: [false, nil])
          .sum { |v| v.ventes_produits.sum(&:quantite) }
      end

      ventes = Caisse::Vente
                 .includes(:client, ventes_produits: :produit)
                 .where(date_vente: jour.all_day, annulee: [false, nil])

      # total_cb      = ventes.sum(:cb).to_d
      # total_amex    = ventes.sum(:amex).to_d
      # total_cheque  = ventes.sum(:cheque).to_d

      base = Caisse::Vente.where(id: ventes.select(:id)) # retire l'effet du includes/join

      total_cb     = base.sum(:cb).to_d
      total_amex   = base.sum(:amex).to_d
      total_cheque = base.sum(:cheque).to_d


      total_especes = ventes.sum do |v|
        espece = v.espece.to_d
        autres = v.cb.to_d + v.cheque.to_d + v.amex.to_d
        rendu  = [espece - (v.total_net.to_d - autres), 0].max
        (espece - rendu).round(2)
      end.round(2)

      total_encaisse = total_cb + total_amex + total_cheque + total_especes

      ###############################################################################################################
      # Initialisation des totaux HT/TVA et des remises
      ht_0                   = 0.to_d
      ttc_0                  = 0.to_d
      ht_20                  = 0.to_d
      ttc_20                 = 0.to_d
      remises_produits_total = 0.to_d
      remises_globales_total = 0.to_d

      ventes.each do |v|
        remise_globale = v.respond_to?(:remise_globale) ? v.remise_globale.to_d : 0
        remises_globales_total += remise_globale

        total_net_sans_remise_globale = v.total_net.to_d + remise_globale

        v.ventes_produits.each do |vp|
          produit       = vp.produit
          quantite      = vp.quantite
          prix_unitaire = (vp.prix_unitaire.to_d.positive? ? vp.prix_unitaire.to_d : produit.prix.to_d)
          brute         = prix_unitaire * quantite
          remise_euros  = (brute * (vp.remise.to_d / 100)).round(2)
          remises_produits_total += remise_euros
          net_apres_prod = (brute - remise_euros).round(2)

          part_remise_globale = if total_net_sans_remise_globale.positive?
            (net_apres_prod / total_net_sans_remise_globale * remise_globale).round(2)
          else
            0.to_d
          end

          net_final = (net_apres_prod - part_remise_globale).round(2)

          if produit.etat == "neuf"
            ttc_20 += net_final
          else
            ttc_0  += net_final
          end
        end
      end

      # Calcul HT / TVA
      ht_20  = (ttc_20 / 1.2).round(2)
      tva_20 = (ttc_20 - ht_20).round(2)
      ht_0   = ttc_0

      total_ht  = (ht_0 + ht_20).round(2)
      total_tva = tva_20
      total_ttc = ventes.sum(&:total_net).round(2)

      total_remises = (remises_produits_total + remises_globales_total).round(2)

      remboursements_du_jour               = Avoir.where(date: jour.all_day).where("motif LIKE ?", "Remboursement produit%")
      total_rembourses                     = remboursements_du_jour.sum(:montant)
      total_ttc_apres_remboursements = total_ttc - total_rembourses

      ###################################################################################################
      # Ticket moyen
      ticket_moyen = total_ventes.positive? ? (total_ttc / total_ventes).round(2) : 0

      fond_caisse_initial = cloture.fond_caisse_initial
      fond_caisse_final   = cloture.fond_caisse_final

      data = OpenStruct.new(
        categorie:                       cloture.categorie,
        date:                            jour,
        ouverture:                       ventes.minimum(:created_at),
        total_ventes:                    cloture.total_ventes,
        total_clients:                   cloture.total_clients,
        total_articles:                  total_articles,
        ticket_moyen:                    ticket_moyen,
        total_cb:                        total_cb,
        total_amex:                      total_amex,
        total_cheque:                    total_cheque,
        total_especes:                   total_especes,
        total_encaisse:                  total_encaisse,
        ht_0:                            ht_0,
        ht_20:                           ht_20,
        ttc_0:                           ttc_0,
        ttc_20:                          ttc_20,
        tva_20:                          tva_20,
        total_ht:                        total_ht,
        total_tva:                       total_tva,
        total_ttc:                       total_ttc,
        total_remises:                   total_remises,
        total_annulations:               total_annulations,
        fond_caisse_initial:             fond_caisse_initial,
        fond_caisse_final:               fond_caisse_final,
        total_versements:                cloture.total_versements || 0,
        total_rembourses:                total_rembourses,
        total_ttc_apres_remboursements: total_ttc_apres_remboursements,
        details_ventes:                 ventes.map do |v|
          total_net   = v.total_net.to_d
          e           = v.espece.to_d
          autres      = v.cb.to_d + v.cheque.to_d + v.amex.to_d
          rendu       = [e - (total_net - autres), 0].max

          {
            numero_vente:  v.id,
            heure:         v.date_vente.strftime("%H:%M"),
            paiement:      "MULTI",
            multi: [
              { "mode" => "CB",     "montant" => v.cb.to_f },
              { "mode" => "Espèces","montant" => e.to_f },
              { "mode" => "Chèque", "montant" => v.cheque.to_f },
              { "mode" => "AMEX",   "montant" => v.amex.to_f }
            ].reject { |p| p["montant"] <= 0 } + (rendu.positive? ? [{ "mode" => "Rendu", "montant" => rendu }] : []),
            remise_globale: v.remise_globale.to_d,
            produits: v.ventes_produits.map do |vp|
              produit         = vp.produit
              prix_unitaire   = vp.prix_unitaire.to_f.positive? ? vp.prix_unitaire.to_f : produit.prix.to_f
              remise_pct      = vp.remise.to_f
              montant_total   = (prix_unitaire * vp.quantite * (1 - remise_pct / 100.0)).round(2)

              {
                nom:           produit.nom.truncate(25),
                etat:          produit.etat.capitalize,
                quantite:      vp.quantite,
                prix_unitaire: prix_unitaire,
                remise:        remise_pct,
                montant_total: montant_total
              }
            end,
            total_vente: total_net
          }
        end,
        details_annulations: ventes_annulees.map do |v|
          {
            numero_vente:     v.id,
            client:           v.client&.nom,
            heure:            v.date_vente.strftime("%H:%M"),
            total:            v.total_net,
            motif_annulation: v.motif_annulation,
            produits:         v.ventes_produits.map do |vp|
              {
                nom:           vp.produit.nom.truncate(25),
                quantite:      vp.quantite,
                prix_unitaire: vp.prix_unitaire,
                remise:        vp.remise
              }
            end
          }
        end,
        details_versements: Versement
                              .includes(client: {}, ventes: { ventes_produits: :produit })
                              .where(created_at: jour.all_day)
                              .map do |vers|
          produits       = vers.ventes.flat_map(&:ventes_produits).map(&:produit)
          produits_client = produits.select { |p| p.client_id == vers.client_id }

          {
            heure:       vers.created_at.strftime("%H:%M"),
            client:      "#{vers.client.nom} #{vers.client.prenom}",
            montant:     vers.montant,
            numero_recu: vers.numero_recu,
            produits:    produits_client.group_by(&:id).map do |_, ps|
              produit   = ps.first
              quantite  = vers.ventes.sum do |v2|
                v2.ventes_produits.where(produit_id: produit.id).sum(:quantite)
              end
              {
                nom:      produit.nom.truncate(25),
                etat:     produit.etat.capitalize,
                quantite: quantite,
                total:    (quantite * produit.prix_deposant).round(2)
              }
            end
          }
        end,
        remboursements_details: remboursements_du_jour.map do |avoir|
          {
            numero: avoir.id,
            montant: avoir.montant,
            motif:   avoir.motif,
            heure:   avoir.created_at.strftime("%H:%M")
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
      # 1) Choix de la date : si params[:date] existe, on l'utilise, sinon on prend aujourd'hui
      jour = params[:date].present? ? Date.parse(params[:date]) : Date.current

      # 2) Ne pas créer si déjà existante
      if Caisse::Cloture.exists?(date: jour, categorie: "journalier")
        return redirect_to ventes_path, alert: "Clôture déjà effectuée pour aujourd’hui."
      end

      # 3) On charge toutes les ventes du jour QUI NE SONT PAS ANNULÉES
      ventes = Caisse::Vente
                .includes(:client, ventes_produits: :produit)
                .where(date_vente: jour.all_day, annulee: [false, nil])

      # 4) On charge les ventes annulées (pour la section « VENTES ANNULÉES »)
      ventes_annulees   = Caisse::Vente.where(date_vente: jour.all_day, annulee: true)
      total_annulations = ventes_annulees.sum(&:total_net)

      # 5) Si aucune vente active, on stoppe
      if ventes.empty?
        return redirect_to ventes_path, alert: "Aucune vente pour aujourd’hui."
      end

      # 6) Statistiques
      total_ventes   = ventes.count
      total_clients  = ventes.map(&:client_id).compact.uniq.size
      total_articles = ventes.sum { |v| v.ventes_produits.sum(&:quantite) }

      # 7) Somme des paiements (une seule fois par vente)
      # total_cb      = ventes.sum(:cb).to_d
      # total_amex    = ventes.sum(:amex).to_d
      # total_cheque  = ventes.sum(:cheque).to_d

      base = Caisse::Vente.where(id: ventes.select(:id)) # retire l'effet du includes/join

      total_cb     = base.sum(:cb).to_d
      total_amex   = base.sum(:amex).to_d
      total_cheque = base.sum(:cheque).to_d


      # 8) Calcul espèces (en retranchant le rendu éventuel)
      total_especes = ventes.sum do |v|
        e       = v.espece.to_d
        autres  = v.cb.to_d + v.cheque.to_d + v.amex.to_d
        rendu   = [e - (v.total_net.to_d - autres), 0].max
        (e - rendu).round(2)
      end.round(2)

      total_encaisse = total_cb + total_amex + total_cheque + total_especes

      ###################################################################################################
      # 9) Calcul des remises et TVA (0 % vs 20 %)
      ht_0                   = 0.to_d
      ttc_0                  = 0.to_d
      ht_20                  = 0.to_d
      ttc_20                 = 0.to_d
      remises_produits_total = 0.to_d
      remises_globales_total = 0.to_d

      ventes.each do |v|
        remise_globale = v.remise_globale.to_d
        remises_globales_total += remise_globale

        total_net_sans_remise_globale = v.total_net.to_d + remise_globale

        v.ventes_produits.each do |vp|
          produit       = vp.produit
          quantite      = vp.quantite
          prix_unitaire = (vp.prix_unitaire.to_d.positive? ? vp.prix_unitaire.to_d : produit.prix.to_d)
          brut          = prix_unitaire * quantite
          remise_euros  = (brut * (vp.remise.to_d / 100)).round(2)
          remises_produits_total += remise_euros
          net_apres_prod = (brut - remise_euros).round(2)

          part_remise_globale = if total_net_sans_remise_globale.positive?
            (net_apres_prod / total_net_sans_remise_globale * remise_globale).round(2)
          else
            0.to_d
          end

          net_final = (net_apres_prod - part_remise_globale).round(2)

          if produit.etat == "neuf"
            ttc_20 += net_final
          else
            ttc_0  += net_final
          end
        end
      end

      # Calcul HT / TVA
      ht_20  = (ttc_20 / 1.2).round(2)
      tva_20 = (ttc_20 - ht_20).round(2)
      ht_0   = ttc_0

      total_ht  = (ht_0 + ht_20).round(2)
      total_tva = tva_20
      total_ttc = ventes.sum(&:total_net).round(2)

      total_remises = (remises_produits_total + remises_globales_total).round(2)

      remboursements_du_jour               = Avoir.where(date: jour.all_day).where("motif LIKE ?", "Remboursement produit%")
      total_rembourses                     = remboursements_du_jour.sum(:montant)
      total_ttc_apres_remboursements = total_ttc - total_rembourses

      ###################################################################################################
      # Ticket moyen
      ticket_moyen = total_ventes.positive? ? (total_ttc / total_ventes).round(2) : 0

      # 15) Fond de caisse initial (0 ou valeur précédente)
      fond_caisse_initial = 0.to_d
      # Si vous souhaitez reprendre le fond final de la clôture d’hier, vous pouvez faire :
      # hier = jour.yesterday
      # cloture_hier = Caisse::Cloture.find_by(date: hier, categorie: "journalier")
      # fond_caisse_initial = cloture_hier.present? ? cloture_hier.fond_caisse_final.to_d : 0.to_d

      # 16) Fond final saisi ou par défaut total espèces
      fond_caisse_final = if params[:fond_caisse_final].present?
        params[:fond_caisse_final].to_d
      else
        total_especes
      end

      # 17) Total versements aux déposants
      total_versements = Versement.where(created_at: jour.all_day).sum(:montant)

      # 18) Création de la clôture journalière
      Caisse::Cloture.create!(
        categorie:           "journalier",
        date:                jour,
        total_ht:            total_ht,
        total_tva:           total_tva,
        total_ttc:           total_ttc,
        total_ventes:        total_ventes,
        total_clients:       total_clients,
        total_articles:      total_articles,
        ticket_moyen:        ticket_moyen,
        total_cb:            total_cb,
        total_amex:          total_amex,
        total_cheque:        total_cheque,
        total_especes:       total_especes,
        total_encaisse:      total_encaisse,
        ht_0:                ht_0,
        ht_20:               ht_20,
        ttc_0:               ttc_0,
        ttc_20:              ttc_20,
        tva_20:              tva_20,
        total_remises:       total_remises,
        total_annulations:   total_annulations,
        fond_caisse_initial: fond_caisse_initial,
        fond_caisse_final:   fond_caisse_final,
        total_versements:    total_versements
      )

      # 19) Génération du ticket texte (Z) en appelant la méthode existante
      data = OpenStruct.new(
        date:                           jour,
        ouverture:                      ventes.minimum(:created_at),
        total_ventes:                   total_ventes,
        total_clients:                  total_clients,
        total_articles:                 total_articles,
        ticket_moyen:                   ticket_moyen,
        total_cb:                       total_cb,
        total_amex:                     total_amex,
        total_cheque:                   total_cheque,
        total_especes:                  total_especes,
        total_encaisse:                 total_encaisse,
        ht_0:                           ht_0,
        ht_20:                          ht_20,
        ttc_0:                          ttc_0,
        ttc_20:                         ttc_20,
        tva_20:                         tva_20,
        total_ht:                       total_ht,
        total_tva:                      total_tva,
        total_ttc:                      total_ttc,
        total_remises:                  total_remises,
        total_annulations:              total_annulations,
        fond_caisse_initial:            fond_caisse_initial,
        fond_caisse_final:              fond_caisse_final,
        total_versements:               total_versements,
        total_rembourses:               total_rembourses,
        total_ttc_apres_remboursements: total_ttc_apres_remboursements,
        details_ventes:
          ventes.map do |v|
            total_net   = v.total_net.to_d
            e           = v.espece.to_d
            autres      = v.cb.to_d + v.cheque.to_d + v.amex.to_d
            rendu       = [e - (total_net - autres), 0].max

            {
              numero_vente:  v.id,
              heure:         v.date_vente.strftime("%H:%M"),
              paiement:      "MULTI",
              multi: [
                { "mode" => "CB",     "montant" => v.cb.to_f },
                { "mode" => "Espèces","montant" => e.to_f },
                { "mode" => "Chèque", "montant" => v.cheque.to_f },
                { "mode" => "AMEX",   "montant" => v.amex.to_f }
              ].reject { |p| p["montant"] <= 0 } + (rendu.positive? ? [{ "mode" => "Rendu", "montant" => rendu }] : []),
              remise_globale: v.remise_globale.to_d,
              produits: v.ventes_produits.map do |vp|
                produit         = vp.produit
                prix_unitaire   = (vp.prix_unitaire.to_f.positive? ? vp.prix_unitaire.to_f : produit.prix.to_f)
                remise_pct      = vp.remise.to_f
                montant_total   = (prix_unitaire * vp.quantite * (1 - remise_pct / 100.0)).round(2)

                {
                  nom:           produit.nom.truncate(25),
                  etat:          produit.etat.capitalize,
                  quantite:      vp.quantite,
                  prix_unitaire: prix_unitaire,
                  remise:        remise_pct,
                  montant_total: montant_total
                }
              end,
              total_vente: total_net
            }
          end,
        details_annulations:
          ventes_annulees.map do |v|
            {
              numero_vente:     v.id,
              client:           v.client&.nom,
              heure:            v.date_vente.strftime("%H:%M"),
              total:            v.total_net,
              motif_annulation: v.motif_annulation,
              produits:         v.ventes_produits.map do |vp|
                {
                  nom:           vp.produit.nom.truncate(25),
                  quantite:      vp.quantite,
                  prix_unitaire: vp.prix_unitaire,
                  remise:        vp.remise
                }
              end
            }
          end,
        details_versements:
          Versement
            .includes(client: {}, ventes: { ventes_produits: :produit })
            .where(created_at: jour.all_day)
            .map do |vers|
              produits        = vers.ventes.flat_map(&:ventes_produits).map(&:produit)
              produits_client = produits.select { |p| p.client_id == vers.client_id }

              {
                heure:       vers.created_at.strftime("%H:%M"),
                client:      "#{vers.client.nom} #{vers.client.prenom}",
                montant:     vers.montant,
                numero_recu: vers.numero_recu,
                produits:    produits_client.group_by(&:id).map do |_, ps|
                  produit   = ps.first
                  quantite  = vers.ventes.sum do |v2|
                    v2.ventes_produits.where(produit_id: produit.id).sum(:quantite)
                  end
                  {
                    nom:      produit.nom.truncate(25),
                    etat:     produit.etat.capitalize,
                    quantite: quantite,
                    total:    (quantite * produit.prix_deposant).round(2)
                  }
                end
              }
            end,
        remboursements_details:
          remboursements_du_jour.map do |avoir|
            {
              numero:  avoir.id,
              montant: avoir.montant,
              motif:   avoir.motif,
              heure:   avoir.created_at.strftime("%H:%M")
            }
          end
      )

      @ticket_z = cloture_ticket_texte(data)
      redirect_to clotures_path, notice: "✅ Clôture générée sans impression automatique."
    end

    ##
    # Prévisualisation de la clôture avec tous les détails
    def preview
      # 1) Récupérer la clôture et sa date
      cloture = Caisse::Cloture.find(params[:id])
      jour    = cloture.date

      # 2) Définir la plage selon la catégorie
      plage = if cloture.categorie == "mensuelle"
        jour.beginning_of_month..jour.end_of_month
      else
        jour.all_day
      end

      # 3) Charger les ventes actives (non annulées) dans la plage
      ventes = Caisse::Vente
                 .includes(:client, ventes_produits: :produit)
                 .where(date_vente: plage, annulee: [false, nil])

      # 4) Charger les ventes annulées (pour la section “VENTES ANNULÉES”)
      ventes_annulees   = Caisse::Vente.where(date_vente: plage, annulee: true)
      total_annulations = ventes_annulees.sum(&:total_net)

      # 5) Statistiques
      total_ventes   = ventes.count
      total_clients  = ventes.map(&:client_id).compact.uniq.size
      total_articles = ventes.sum { |v| v.ventes_produits.sum(&:quantite) }

      # 6) Somme des paiements (une seule fois par vente)
      # total_cb     = ventes.sum(:cb).to_d
      # total_amex   = ventes.sum(:amex).to_d
      # total_cheque = ventes.sum(:cheque).to_d

      base = Caisse::Vente.where(id: ventes.select(:id)) # retire l'effet du includes/join

      total_cb     = base.sum(:cb).to_d
      total_amex   = base.sum(:amex).to_d
      total_cheque = base.sum(:cheque).to_d


      # 7) Calcul espèces (en retranchant le rendu éventuel par vente)
      total_especes = ventes.sum do |v|
        e       = v.espece.to_d
        autres  = v.cb.to_d + v.cheque.to_d + v.amex.to_d
        rendu   = [e - (v.total_net.to_d - autres), 0].max
        (e - rendu).round(2)
      end.round(2)

      total_encaisse = total_cb + total_amex + total_cheque + total_especes

      ################################################################################
      # 8) Initialisation des totaux HT/TVA et des remises
      ht_0                    = 0.to_d
      ttc_0                   = 0.to_d
      ht_20                   = 0.to_d
      ttc_20                  = 0.to_d
      remises_produits_total  = 0.to_d
      remises_globales_total  = 0.to_d

      # 9) Parcours de chaque vente active pour répartir remises et TVA
      ventes.each do |v|
        remise_globale = v.remise_globale.to_d
        remises_globales_total += remise_globale

        total_net_sans_remise_globale = v.total_net.to_d + remise_globale

        v.ventes_produits.each do |vp|
          produit       = vp.produit
          quantite      = vp.quantite
          prix_u        = (vp.prix_unitaire.to_d.positive? ? vp.prix_unitaire.to_d : produit.prix.to_d)
          brut          = prix_u * quantite
          remise_euros  = (brut * (vp.remise.to_d / 100)).round(2)
          remises_produits_total += remise_euros
          net_apres_prod = (brut - remise_euros).round(2)

          part_remise_globale = if total_net_sans_remise_globale.positive?
            (net_apres_prod / total_net_sans_remise_globale * remise_globale).round(2)
          else
            0.to_d
          end

          net_final = (net_apres_prod - part_remise_globale).round(2)

          if produit.etat == "neuf"
            ttc_20 += net_final
          else
            ttc_0  += net_final
          end
        end
      end

      # 10) Calcul HT / TVA pour le taux 20 %
      ht_20  = (ttc_20 / 1.2).round(2)
      tva_20 = (ttc_20 - ht_20).round(2)

      # 11) Pour le taux 0 %, TVA toujours zéro
      ht_0 = ttc_0

      # 12) Totaux finaux
      total_ht  = (ht_0 + ht_20).round(2)
      total_tva = tva_20
      total_ttc = ventes.sum(&:total_net).round(2)

      total_remises = (remises_produits_total + remises_globales_total).round(2)

      # 13) Remboursements (avoirs)
      remboursements_du_jour               = Avoir.where(date: jour.all_day).where("motif LIKE ?", "Remboursement produit%")
      total_rembourses                     = remboursements_du_jour.sum(:montant)
      total_ttc_apres_remboursements = total_ttc - total_rembourses

      ##########################################################################################
      # 14) Ticket moyen
      ticket_moyen = total_ventes.positive? ? (total_ttc / total_ventes).round(2) : 0

      # 15) Fond de caisse initial et final déjà enregistrés dans la clôture
      fond_caisse_initial = cloture.fond_caisse_initial
      fond_caisse_final   = cloture.fond_caisse_final
      total_versements    = cloture.total_versements

      # 16) Construction de l’OpenStruct pour la génération du ticket
      data = OpenStruct.new(
        categorie:                       cloture.categorie,
        date:                            jour,
        ouverture:                       ventes.minimum(:created_at),
        total_ventes:                    total_ventes,
        total_clients:                   total_clients,
        total_articles:                  total_articles,
        ticket_moyen:                    ticket_moyen,
        total_cb:                        total_cb,
        total_amex:                      total_amex,
        total_cheque:                    total_cheque,
        total_especes:                   total_especes,
        total_encaisse:                  total_encaisse,
        ht_0:                            ht_0,
        ht_20:                           ht_20,
        ttc_0:                           ttc_0,
        ttc_20:                          ttc_20,
        tva_20:                          tva_20,
        total_ht:                        total_ht,
        total_tva:                       total_tva,
        total_ttc:                       total_ttc,
        total_remises:                   total_remises,
        total_annulations:               total_annulations,
        fond_caisse_initial:             fond_caisse_initial,
        fond_caisse_final:               fond_caisse_final,
        total_versements:                total_versements,
        total_rembourses:                total_rembourses,
        total_ttc_apres_remboursements: total_ttc_apres_remboursements,
        details_ventes:                 ventes.map do |v|
          total_net   = v.total_net.to_d
          espece      = v.espece.to_d
          autres      = v.cb.to_d + v.cheque.to_d + v.amex.to_d
          rendu       = [espece - (total_net - autres), 0].max

          {
            numero_vente:  v.id,
            heure:         v.date_vente.strftime("%H:%M"),
            paiement:      "MULTI",
            multi: [
              { "mode" => "CB",     "montant" => v.cb.to_f },
              { "mode" => "Espèces","montant" => espece.to_f },
              { "mode" => "Chèque", "montant" => v.cheque.to_f },
              { "mode" => "AMEX",   "montant" => v.amex.to_f }
            ].reject { |p| p["montant"] <= 0 } + (rendu.positive? ? [{ "mode" => "Rendu", "montant" => rendu }] : []),
            remise_globale: v.remise_globale.to_d,
            produits: v.ventes_produits.map do |vp|
              produit         = vp.produit
              prix_unitaire   = (vp.prix_unitaire.to_f.positive? ? vp.prix_unitaire.to_f : produit.prix.to_f)
              remise_pct      = vp.remise.to_f
              montant_total   = (prix_unitaire * vp.quantite * (1 - remise_pct / 100.0)).round(2)

              {
                nom:           produit.nom.truncate(25),
                etat:          produit.etat.capitalize,
                quantite:      vp.quantite,
                prix_unitaire: prix_unitaire,
                remise:        remise_pct,
                montant_total: montant_total
              }
            end,
            total_vente: total_net
          }
        end,
        details_annulations:
          ventes_annulees.map do |v|
            {
              numero_vente:     v.id,
              client:           v.client&.nom,
              heure:            v.date_vente.strftime("%H:%M"),
              total:            v.total_net,
              motif_annulation: v.motif_annulation,
              produits:         v.ventes_produits.map do |vp|
                {
                  nom:           vp.produit.nom.truncate(25),
                  quantite:      vp.quantite,
                  prix_unitaire: vp.prix_unitaire,
                  remise:        vp.remise
                }
              end
            }
          end,
        details_versements:
          Versement
            .includes(client: {}, ventes: { ventes_produits: :produit })
            .where(created_at: plage)
            .map do |vers|
              produits        = vers.ventes.flat_map(&:ventes_produits).map(&:produit)
              produits_client = produits.select { |p| p.client_id == vers.client_id }

              {
                heure:       vers.created_at.strftime("%H:%M"),
                client:      "#{vers.client.nom} #{vers.client.prenom}",
                montant:     vers.montant,
                numero_recu: vers.numero_recu,
                produits:    produits_client.group_by(&:id).map do |_, ps|
                  produit   = ps.first
                  quantite  = vers.ventes.sum do |v2|
                    v2.ventes_produits.where(produit_id: produit.id).sum(:quantite)
                  end
                  {
                    nom:      produit.nom.truncate(25),
                    etat:     produit.etat.capitalize,
                    quantite: quantite,
                    total:    (quantite * produit.prix_deposant).round(2)
                  }
                end
              }
            end,
        remboursements_details:
          remboursements_du_jour.map do |avoir|
            {
              numero:  avoir.id,
              montant: avoir.montant,
              motif:   avoir.motif,
              heure:   avoir.created_at.strftime("%H:%M")
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
      lignes  = []

      # En-tête
      lignes << "ROMANCE".center(largeur)
      lignes << "C.C. Val Lumière".center(largeur)
      lignes << "5 Rue Jacques Yves Cousteau".center(largeur)
      lignes << "17640 Vaux-sur-Mer".center(largeur)
      lignes << "SIRET : 832 259 837 00031".center(largeur)
      titre = data.categorie == "mensuelle" ? "Clôture mensuelle" : "Clôture de caisse Z"
      lignes << titre.center(largeur)
      lignes << I18n.l(data.date, format: :long).center(largeur)
      lignes << "-" * largeur

      # 2️⃣ Dates
      lignes << "Ouverture : #{I18n.l(data.ouverture || data.date.beginning_of_day, format: :long)}"
      lignes << "Clôture   : #{I18n.l(data.date, format: :long)} à 20:00"
      lignes << "-" * largeur

      # 3️⃣ Statistiques
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

      # 7️⃣ Remises & Annulations
      lignes << "REMISES ET ANNULATIONS"
      lignes << "Total remises         : #{format('%.2f €', data.total_remises)}"
      lignes << "Total annulations     : #{format('%.2f €', data.total_annulations)}"
      lignes << "-" * largeur

      # ✅ Remboursements produits
      lignes << "REMBOURSEMENTS PRODUITS"
      if data.respond_to?(:remboursements_details) && data.remboursements_details.any?
        data.remboursements_details.each do |r|
          lignes << "#{r[:heure]} - Avoir n°#{r[:numero]} - #{r[:motif]} - #{format('%.2f €', r[:montant])}"
        end
      else
        lignes << "Aucun remboursement ce jour"
      end
      lignes << ""
      lignes << "Montant total remboursé : #{format('%.2f €', data.total_rembourses)}"
      lignes << "-" * largeur

      # VENTES ANNULÉES
      lignes << "VENTES ANNULÉES"
      if data.details_annulations.present? && data.details_annulations.any?
        data.details_annulations.each do |annulation|
          client = annulation[:client].to_s
          heure  = annulation[:heure].to_s
          total  = annulation[:total] || 0
          motif  = annulation[:motif_annulation].to_s.strip

          lignes << "N°#{annulation[:numero_vente]} - #{client} - #{heure} - Total : #{sprintf('%.2f', total)}€"
          lignes << "Motif : #{motif}" if motif.present?

          (annulation[:produits] || []).each do |prod|
            nom          = prod[:nom].to_s
            quantite     = prod[:quantite] || 0
            prix_unitaire = prod[:prix_unitaire] || 0
            remise       = prod[:remise] || 0
            lignes << "   #{nom} x#{quantite} à #{sprintf('%.2f', prix_unitaire)}€ (remise #{remise}%)"
          end
        end
      else
        lignes << "(aucune vente annulée)"
      end
      lignes << "-" * largeur

      unless data.categorie == "mensuelle"
        total_ventes_especes = Caisse::Vente
                                .where(date_vente: data.date.all_day, annulee: [false, nil])
                                .sum(:espece).to_f
        fond_theorique = data.fond_caisse_initial.to_f +
                          MouvementEspece.where(date: data.date, sens: "entrée").sum(:montant).to_f -
                          MouvementEspece.where(date: data.date, sens: "sortie").sum(:montant).to_f -
                          data.total_versements.to_f 
        difference = data.fond_caisse_final.to_f - fond_theorique

        lignes << "FOND DE CAISSE"
        lignes << "Initial        : #{format('%.2f €', data.fond_caisse_initial.to_f)}"
        lignes << "Théorique     : #{format('%.2f €', fond_theorique)}"
        lignes << "Final (compté) : #{format('%.2f €', data.fond_caisse_final.to_f)}"
        lignes << "Différence     : #{format('%+.2f €', difference)}"
        lignes << "-" * largeur
      end

      # Versements aux déposants
      lignes << "VERSEMENTS AUX DEPOSANTS"
      lignes << ""
      lignes << "Total versé : #{format('%.2f €', data.total_versements.to_f)}"
      lignes << "-" * largeur

      # 8️⃣ Détail des ventes
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
          if prod[:remise].to_f.positive?
            remise_euros = (prod[:prix_unitaire] * prod[:quantite] * (prod[:remise].to_f / 100)).round(2)
            lignes << "    Remise : -#{'%.2f €' % remise_euros} (#{prod[:remise].to_i} %)"
          end
          lignes << "    Total : #{'%.2f €' % prod[:montant_total]}"
        end

        if vente[:remise_globale].to_f.positive?
          lignes << "    Remise globale : -#{'%.2f €' % vente[:remise_globale]}"
        end

        lignes << "  -> Total vente : #{'%.2f €' % vente[:total_vente]}"
        lignes << "-" * largeur
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

      # 10) Message de clôture
      lignes << ""
      lignes << "Merci et à demain !".center(largeur)
      lignes << "\n" * 10

      lignes.join("\n")
    end
  end
end
