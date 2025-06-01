````markdown
# Projet Caisse

Ce dépôt contient le module **Caisse** de l’application Boutique. Il gère la gestion des ventes, des mouvements en espèces, des remboursements et des clôtures journalières/mensuelles de caisse.

---

## Table des matières

1. [Présentation](#présentation)  
2. [Fonctionnalités principales](#fonctionnalités-principales)  
3. [Prérequis](#prérequis)  
4. [Installation & Configuration](#installation--configuration)  
5. [Structure du projet](#structure-du-projet)  
6. [Utilisation](#utilisation)  
   - [1. Gestion des ventes](#1-gestion-des-ventes)  
   - [2. Remboursements](#2-remboursements)  
   - [3. Mouvements en espèces](#3-mouvements-en-espèces)  
   - [4. Clôtures de caisse](#4-clôtures-de-caisse)  
7. [Tâches Rake utiles](#tâches-rake-utiles)  
8. [Tests](#tests)  
9. [Contribuer](#contribuer)  
10. [Licence](#licence)  

---

## Présentation

Le module **Caisse** gère l’ensemble des opérations liées à la caisse du point de vente :

- **Ventes** : création de factures, calcul des remises (produit et globale), enregistrement des paiements (CB, espèces, chèque, AMEX), mise à jour de stock.
- **Remboursements** : annulation de vente, restitution en espèces ou création d’un avoir client.
- **Mouvements en espèces** : suivi du flux d’entrées et de sorties en espèces (encaissements, rendus, apports, retraits).
- **Clôtures journalières (ticket Z)** : synthèse des ventes du jour, calcul HT/TVA/TTC, fond de caisse, affichage du détail des ventes/annulations/versements.
- **Clôtures mensuelles** : agrégation des clôtures journalières ou calcul direct sur toutes les ventes du mois, génération et impression du ticket mensuel.

---

## Fonctionnalités principales

1. **Ventes**  
   - Création d’une vente multi-produits  
   - Prise en compte des remises par ligne et remise globale  
   - Calcul automatique du rendu en espèces  
   - Décrémentation du stock produit  

2. **Remboursements**  
   - Annulation d’une vente (réallocation de stock)  
   - Remboursement en espèces ou conversion en avoir client  
   - Éviter les doublons dans les mouvements en espèces (vérification par motif)  

3. **Mouvements en espèces**  
   - Encaissement automatique lors d’une vente en espèces  
   - Enregistrement du rendu de monnaie  
   - Saisie manuelle : apports, retraits, dépôts sur compte pro, etc.  
   - Calcul du fond de caisse « actuel » (entrées – sorties – versements + ventes en espèces)

4. **Clôtures de caisse**  
   - **Clôture journalière (Z)**  
     - Synthèse des ventes non annulées du jour  
     - Calcul HT/TVA/​TTC par taux (0 % / 20 %)  
     - Fond de caisse théorique vs montant compté  
     - Détail des ventes, annulations, remboursements, versements  
   - **Clôture mensuelle**  
     - Agrégation des Z journalières du mois (ou calcul direct sur les ventes)  
     - Répartition des remises globales au prorata de chaque ligne (identique à la journalière)  
     - Impression du ticket mensuel  

---

## Prérequis

- **Ruby** : 2.7 ou version supérieure  
- **Rails** : 6.1.x (ou version utilisée dans l’application Boutique)  
- **Base de données** : PostgreSQL (ou SQLite en environnement de développement)  
- **Bundler** (gem)  
- **Prise en charge de l’impression** : `lp` (CUPS) avec pilote SEWOO_LKT_Series pour tickets thermiques  

---

## Installation & Configuration

1. **Cloner le dépôt**  
   ```bash
   git clone https://github.com/votre-organisation/caisse.git
   cd caisse
````

2. **Installer les dépendances**

   ```bash
   bundle install
   yarn install    # si vous utilisez webpacker pour les assets JS
   ```

3. **Configurer la base de données**

   * Copiez (ou modifiez) `config/database.yml` pour pointer vers votre instance PostgreSQL (ou SQLite).
   * Créez la base et exécutez les migrations :

     ```bash
     rails db:create
     rails db:migrate
     rails db:seed      # (optionnel) si vous avez des données de démonstration
     ```

4. **Configurer les variables d’environnement (le cas échéant)**

   * Par exemple, si vous utilisez `config/credentials.yml.enc` pour des clés externes, assurez-vous de chiffrer/déchiffrer avec `rails credentials:edit`.
   * Ajoutez vos paramètres de connexion SMS/SMTP si nécessaire (pour envois de notifications, etc.).

5. **Démarrer le serveur Rails**

   ```bash
   rails server
   ```

   Par défaut, l’application s’expose sur `http://localhost:3000`. Vous pouvez accéder au module Caisse via `/caisse`.

---

## Structure du projet

```
caisse/
├── app/
│   ├── controllers/
│   │   ├── caisse/
│   │   │   ├── ventes_controller.rb
│   │   │   ├── clotures_controller.rb
│   │   │   ├── remboursements_controller.rb
│   │   │   └── especes_controller.rb
│   │   └── application_controller.rb
│   ├── models/
│   │   ├── caisse/
│   │   │   ├── vente.rb
│   │   │   ├── cloture.rb
│   │   │   └── ...
│   │   ├── mouvement_espece.rb
│   │   ├── versement.rb
│   │   ├── avoir.rb
│   │   └── produit.rb
│   ├── views/
│   │   ├── caisse/
│   │   │   ├── ventes/
│   │   │   ├── clotures/
│   │   │   ├── remboursement/
│   │   │   └── especes/
│   │   └── layouts/
│   └── helpers/
├── config/
│   ├── routes.rb        # Routes principales
│   ├── database.yml
│   └── initializers/
│       └── taxe.rb      # (exemple) configuration taux TVA
├── db/
│   ├── migrate/
│   │   ├── xxxx_create_ventes.rb
│   │   ├── xxxx_create_clotures.rb
│   │   ├── xxxx_create_mouvement_especes.rb
│   │   └── ...
│   └── schema.rb
├── lib/
│   └── tasks/           # Tâches Rake spécifiques
├── public/              
├── Gemfile
├── Gemfile.lock
├── Rakefile
└── README.md            # Ce fichier
```

---

## Utilisation

### 1. Gestion des ventes

* **Ajouter un produit au panier** sur l’UI via `POST /caisse/ventes/recherche_produit` ou boutons dédiés.
* **Modifier quantité/prix/remise** : via `POST /caisse/ventes/modifier_quantite` et `POST /caisse/ventes/modifier_prix`.
* **Saisir le client** ou cocher « Sans client ».
* **Appliquer une remise globale** (champ `remise_globale_manuel`).
* **Sélection du mode de paiement** :

  * `espece`, `cb`, `cheque`, `amex`
  * Le calcul du rendu en espèces est automatique (crée un `MouvementEspece` de type `sortie`).
* **Valider la vente** : la route `POST /caisse/ventes` crée l’enregistrement `Caisse::Vente` et ajuste le stock produit.
* **Annulation d’une vente** :

  * Bouton / lien « Annuler » dans la liste des ventes, action `PATCH /caisse/ventes/:id/annuler`
  * Remise du stock, création d’un `MouvementEspece` (si espèces) ou d’un avoir, selon l’option choisie.

### 2. Remboursements

* **Lister les remboursements** : accédez à `GET /caisse/remboursements`
* **Créer un remboursement** : via `caisse/ventes#remboursement` (formulaire sur une vente existante)
* **Modes de remboursement** :

  * En espèces (`MouvementEspece` de type `sortie`)
  * Par CB remboursé en espèces (`sortie`)
  * Ou création d’un **avoir** client (modèle `Avoir`).

### 3. Mouvements en espèces

* **Vue des mouvements** : `GET /especes`

  * Affiche toutes les entrées/sorties (modèle `MouvementEspece`) triées par date et type.
  * Calcule le **fond de caisse actuel** :

    ```ruby
    fond_initial = 0
    total_entrees = MouvementEspece.where(date: aujourd_hui, sens: "entrée").sum(:montant)
    total_sorties = MouvementEspece.where(date: aujourd_hui, sens: "sortie").sum(:montant)
    total_versements = Versement.where(methode_paiement: "Espèces", created_at: aujourd_hui.all_day).sum(:montant)
    total_ventes_especes = Caisse::Vente.where(date_vente: aujourd_hui.all_day, annulee: [false, nil]).sum(:espece)

    fond_de_caisse = fond_initial + total_entrees - total_sorties - total_versements + total_ventes_especes
    ```
* **Encaissement automatique** (lors d’une vente en espèces) et **rendu monnaie** généré par `EspecesController#create` si `params[:vente_id]` est présent.
* **Saisie manuelle** de type « Apport banque », « Apport perso », « Retrait perso », « Dépôt compte pro ».

### 4. Clôtures de caisse

#### a. Clôture journalière (Ticket Z)

* **Générer** :

  * Soit via `POST /caisse/clotures/cloture_z` (si pas de param. `date`, prend `Date.current`).
  * Vérifie d’abord qu’aucune clôture journalière n’existe déjà pour le jour.
  * Récupère toutes les ventes non annulées `date_vente: jour.all_day`, calcule HT/TVA/TTC par ligne exactement comme expliqué plus haut, ajuste le fond de caisse, enregistre un `Caisse::Cloture` de type `journalier`.
* **Imprimer / Prévisualiser** :

  * `GET /caisse/clotures/:id/imprimer` → imprime via CUPS le ticket Z.
  * `GET /caisse/clotures/:id/preview` → retourne dans `@ticket_z` le contenu texte (affiché en HTML).

#### b. Clôture mensuelle

* **Formulaire** : sur la page `GET /caisse/clotures`, un champ “Mois (AAAA-MM)”.
* **Générer** : `POST /caisse/clotures/cloture_mensuelle` →

  1. Vérifie qu’aucune clôture mensuelle n’existe pour le dernier jour du mois.
  2. Récupère toutes les ventes non annulées de `debut_mois..fin_mois`, calcule HT/TVA/TTC ligne par ligne (identique à Z journalière).
  3. Agrège les totaux de chaque Z journalière (facultatif).
  4. Enregistre `Caisse::Cloture` de type `mensuelle`.
  5. Imprime le ticket mensuel via CUPS.

---

## Tâches Rake utiles

Quelques tâches personnalisées (si disponibles dans `lib/tasks`) :

* **db\:seed\:caisse** : peuple des données de démonstration pour Caisse (produits, clients, etc.).
* **cloture\:quotidienne** : génère en script la clôture Z du jour.
* **cloture\:mensuelle** : génère en script la clôture mensuelle pour `mthemonth` (format `YYYY-MM`).

*(Adapter ces noms de tâches si elles ne sont pas existantes — ou les créer dans `lib/tasks`.)*

---

## Tests

Si vous avez mis en place des specs RSpec ou des tests Minitest :

1. **Installer les gems de test** (RSpec, FactoryBot, etc.) :

   ```bash
   bundle install --with test
   ```
2. **Lancer la suite** :

   * RSpec : `bundle exec rspec`
   * Minitest : `rails test`

Vérifiez que toutes les fonctionnalités (vente, remboursement, mouvement\_espece, clôtures) sont couvertes.

---

## Contribuer

1. Forkez ce dépôt.
2. Créez une branche de fonctionnalité : `git checkout -b feature/ma-nouvelle-fonctionnalité`
3. Codez vos changements et ajoutez des tests.
4. Faites un commit clair :

   ```
   git add .
   git commit -m "Ajoute XYZ dans cloture_z pour gérer le cas ABC"
   ```
5. Poussez votre branche sur votre fork et créez une Pull Request.
6. Attendez la revue, corrigez éventuels retours, puis fusionnez.

---

## Licence

Ce projet est distribué sous licence **MIT**. Voir le fichier [LICENSE](LICENSE) pour plus de détails.

---

> **Note :** Le module Caisse fait partie de l’application [Boutique](https://github.com/votre-organisation/boutique), qui l’intègre en tant que moteur Rails (Engine). Pour toute modification, assurez-vous que les routes et migrations de Caisse restent cohérentes lorsqu’elles sont appelées depuis l’application principale.

```
```
