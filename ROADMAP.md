# Feuille de route - working_villages

## Vision

Transformer les villages de Minetest en communautés vivantes et autonomes où les villageois travaillent, interagissent et construisent ensemble.

## Etat de la branche (2026-08-27)

### Limite des preuves actuelles

- Le code et des scénarios automatisés sur serveur Luanti 5.17.0 headless ont
  été vérifiés avec les profils VoxeLibre et Minetest Game, notamment pour le
  chargement/rechargement, le spawn, le foyer, les inventaires et les portes.
- Les scénarios VoxeLibre complets ont utilisé une copie jetable isolée dont la
  métadonnée de dépendance de `vl_hudbars` a été corrigée pour contourner un
  problème d'ordre de chargement du jeu. L'installation locale 0.92.1 passe
  aussi le harnais principal après la même correction, mais une installation
  intacte n'a donc toujours pas été validée.
- Aucun parcours avec client graphique, aucun cycle métier complet et aucune
  économie autonome de bout en bout n'ont été joués manuellement dans l'un ou
  l'autre jeu.
- Le scénario headless v12 part d'un monde VoxeLibre neuf et conserve cinq PNJ
  au moins 273 secondes. Il atteint le coffre commun, cinq outils, 31 arbres,
  des cultures semées et mûres, une récolte et des échanges physiques. Il ne
  confirme encore ni minerai/dépôt, ni four, ni chantier, ni reprise après
  redémarrage.
- Les essais v17 et v18 sont des échecs diagnostiques sans verdict terminal ;
  v19 est préparé mais n'a pas encore été exécuté.
- Dans ce document, « intégré » signifie que le chemin existe dans le code.
  Cela ne signifie pas que le comportement est équilibré, agréable à jouer ou
  compatible de bout en bout.
- Le mode par défaut est `survival`. `creative_test` ouvre seulement des
  raccourcis explicites de développement et ne constitue pas une preuve de
  l'économie de survie.
- Les six recettes directes enregistrées concernent le sceptre de commande, la
  fiche de métier vide, la fiche d'apprenant, la botte de paille, le lit
  agricole et le pain plat. La couverture des recettes de professions reste
  incomplète.
- Douze plans par défaut sont réellement enregistrés ; toute ancienne mention
  de dix plans est obsolète.

### Ajouts récents intégrés

- Couche de compatibilité VoxeLibre/Minetest Game centralisée via `compat/vl.lua`, avec tests headless ciblés sur les deux profils
- Systèmes de besoins, mémoire persistante, permissions et HUD permanent branchés sur la boucle de vie des villageois
- Enrichissement des métiers `builder`, `blacksmith`, `guard`, `farmer`, `woodcutter`, `miner` et ajout du métier `cook`
- Moteur de craft partagé : lecture des recettes enregistrées, sous-recettes, résolution des groupes d'items et comptabilité du coffre commun ; les cycles métiers complets restent à jouer
- Logique de bootstrap : commande de redéfinition du coffre partagé, cache synchronisé, tentative de pose du premier coffre par l'autonome et claim autour de ce coffre
- Phase bootstrap explicite pour le debut du village : bois -> coffre commun -> nourriture -> outils/artisanat -> defense -> premier chantier
- Builder réaffecté en soutien logistique avant la phase build : ravitaillement du coffre, collecte ciblée, coupe de bois et récolte d'appoint
- Gestion persistante des propriétaires et des villages `self_employed` ; le groupe initial exact est woodcutter, farmer, autonomous, miner et builder
- Pilotage du village via dialogues : rapport, priorité stratégique, niveau de notifications, prochain chantier forcé et phase bootstrap visible
- Sceptre de commande enrichi : accès direct au pilotage du village et bouton `Mode IA` pour relancer craft, entraide et réévaluation immédiate des jobs
- Commandes d'exploitation/admin : `wv_spawn5`, `wv_storage_show`, `wv_blacksmith_order`, `wv_blacksmith_output`, `wv_building_cleanup`, `villager_experiment`
- Spawn initial durci : chargement de zone, recherche d'une vraie surface, et annulation du spawn si aucune position valide n'est trouvée
- Reprise des jobs durcie : `on_start` rejoué lors de la recréation d'un thread de métier pour éviter les jobs partiellement réinitialisés
- Chemins de survie ajoutés pour les non-gardes : armement d'urgence, recherche d'abri et fuite/repli ; le vrai `on_step` de retraite passe le harnais moteur alpha.4 dans les deux profils, mais son efficacité contre les mobs natifs reste non mesurée en partie
- Builder renforcé en contexte dangereux : priorisation des abris d'urgence, cadence autonome plus rapide et préparation des matériaux par lots
- Branchements aux inventaires de fours pour le forgeron et le cuisinier, avec comptabilité/callbacks testés de façon ciblée ; cycle métier complet non joué
- Maisons construites auto-configurées quand possible : détection du lit et d'un accès exploitable au marqueur de maison en fin de chantier
- Woodcutter remis sur la couche de protection propriétaire pour éviter les coupes en zones protégées
- Builder et miner moins bruyants : suppression des `print` bruts restants, pauses explicites sur étapes/filons inaccessibles et états d'attente plus lisibles
- Coffres pré-vérifiés avant navigation, avec attente vide adaptative de deux à
  quatre secondes ; un objet utile injecté dans la régression est repris sous
  quatre secondes et les messages d'action ne sont émis que pour un échange réel
- Mineur capable de convertir le bois partagé en pioche en bois à coût exact,
  puis d'extraire et déposer un vrai minerai dans les deux profils
- Fermier capable d'obtenir une graine naturelle, de labourer et de semer dans
  les deux profils ; le run v12 atteint aussi la maturité et une récolte
- Livraison physique vers un demandeur mobile, proximité obligatoire, reprise
  du rendez-vous après redémarrage et recontrôle sans duplication dans les deux
  profils
- Anti-encastrement conservateur : cache sûr revalidé dès le premier callback,
  sinon recherche locale après trois callbacks, sans extraire un mineur d'une
  cavité praticable
- Registre persistant des chantiers avec migration par scan borné unique, puis
  chemin rapide validé sur 250 consultations de rayon 50
- Seize spécifications autonomes passées dans les deux profils, complétées par
  les tests moteur de compatibilité, de registre et de vraies recettes minerai

## Objectifs à court terme (Version 0.x - Actuelle)

### ✅ Présent dans le code ou couvert par un test ciblé

- [x] Système de base des villageois
- [x] Enregistrement et chargement de multiples métiers (fonctionnement de bout en bout encore à valider)
- [x] Système de blueprints avec apprentissage
- [x] Détection et couche de compatibilité pour VoxeLibre et Minetest Game
- [x] Métiers spécialisés (blacksmith, miner)
- [x] Système d'expérience
- [x] Gestion des coffres et inventaires
- [x] Appels de pathfinding et traitement des échecs terminaux branchés
- [x] Protection des zones
- [x] Communication inter-villageois et tâches collaboratives
- [x] Job cuisinier et chemin de cuisson communautaire présents dans le code
- [x] HUD villageois, mémoire persistante et demandes d'autorisation
- [x] Craft partagé avec sous-recettes et comptabilité ciblée du coffre commun
- [x] Logique d'amorçage : rôle autonome initial, coffre commun réinitialisable et claim centré sur le coffre
- [x] Début de village coordonné par phases bootstrap avant ouverture du premier chantier autonome
- [x] Pilotage du village via rapports, priorités, notifications et ordres de chantier
- [x] Spawn initial de 5 PNJ avec relance admin et sécurité anti-spawn sous terre
- [x] Résilience des jobs avec reprise automatique après erreur
- [x] Repli d'urgence, abris et armement minimal pour les villageois non-combattants
- [x] Accès aux inventaires de four et logique d'auto-configuration des maisons, avec tests ciblés mais sans cycle métier manuel complet

### 🔄 En cours

- [ ] Documentation complète de l'API
  - [ ] Chapitre compat VoxeLibre : mapping nodes/objets (portes, lits colorés, coffres, agriculture)
  - [ ] Pages métiers : comportements spécifiques VoxeLibre (guard/miner/blacksmith avec `mcl_*`)
  - [ ] Guides d'extension : détection VoxeLibre/minetest_game et usage des helpers de compat
- [ ] Stabilisation et validation du spawn
  - [x] Recherche de surface et chargement de zone présents ; création/persistance testées sur serveur headless
  - [ ] Validation manuelle en mondes plats et vallonnés, séparément dans VoxeLibre intact et Minetest Game
  - [ ] Revoir le spawn ABM (arbres/herbes) pour limiter les cas de grottes ouvertes
- [ ] Refactorisation du code dupliqué
  - [ ] Mutualiser les helpers de compat (portes, lits, torches, farming) dans un module unique
  - [ ] Factoriser les schémas de jobs qui varient entre VoxeLibre et minetest_game
  - [ ] Centraliser les conversions d'items (default ↔ mcl) pour éviter les branches locales
- [ ] Amélioration des performances
  - [ ] Profiling ciblé en environnement VoxeLibre (mondes mcl_* plus denses, pathfinding différent)
  - [ ] Mise en cache des résolutions de nodes compatibles (ex : lookup portes/torches)
  - [ ] Réduction des scans de sol pour les cultures VoxeLibre (stages de croissance plus nombreux)
- [ ] Couverture automatisée et manuelle complète
  - [x] Couverture ciblée des helpers de compatibilité, de la persistance, des timers et de la comptabilité d'inventaire
  - [ ] Tests de jobs majeurs en mode VoxeLibre (farmer, builder, miner, blacksmith)
  - [x] Régression headless de création et persistance du spawn initial
  - [ ] Validation manuelle de la relance `/wv_spawn5`
- [x] Détection et démarrage headless des profils VoxeLibre et Minetest Game
- [x] Livraison physique ciblée entre deux PNJ, avec conservation exacte et reprise après redémarrage, dans les deux profils
- [x] Fermier ciblé : graine naturelle, labour et semis dans les deux profils
- [x] Mineur ciblé : ressources comptées, pioche capable, vrai minerai et dépôt dans les deux profils
- [x] Livraison ciblée à demandeur mobile : pas de transfert à distance,
  reprise après redémarrage et absence de duplication au recontrôle
- [x] Cadence de coffre vide : aucun trajet/manipulation sur 221 décisions et
  reprise d'un objet utile injecté dans le test sous quatre secondes
- [x] Registre de chantier : migration ancienne bornée, transitions/destruction
  synchronisées et 250 consultations sur le chemin rapide
- [x] Recettes moteur du fer et de l'or vérifiées dans les deux profils
- [ ] Run village complet v12 : coffre, cinq outils, 31 arbres, semis, maturité,
  une récolte et échanges atteints ; minerai/dépôt, four, chantier et phase 2
  après redémarrage restent ouverts
- [ ] Chaînes terminales de chaque métier et village complet avec client connecté

### Plan de dev VoxeLibre (actionnable)

- [x] Compat unifiée
  - [x] Module `working_villagers/compat/vl.lua` : mappings explicites `default:*` ↔ `mcl_*`, portes/lits/torches/coffres/farming, chargé par le loader local sans dépendance d'exécution à `modutil`
  - [x] API utilitaires : `compat.get_node(name)`, `compat.get_item(name)`, `compat.get_growth_stage(node)`, `compat.is_door(node)`, `compat.bed_meta(node)`
- [ ] Intégration jobs
  - [x] Adapter les jobs farmer, builder, miner, blacksmith pour appeler `compat.*` (retrait des branches locales `if mcl_core then ...`)
  - [ ] Ajouter un test manuel rapide (world VoxeLibre) pour chaque job : placer node cible, vérifier action, logger résultat
- [ ] Détection et réglages
  - [x] Centraliser la détection VoxeLibre/minetest_game dans `init.lua` et exposer `working_villages.game_profile`
  - [ ] Paramétrer les valeurs spécifiques VoxeLibre (vitesse de croissance, toolcaps) dans `settings.lua`
- [x] Tests automatisés ciblés
  - [x] Scénarios headless de chargement, mappings, stockage et inventaires sur les deux profils
  - [x] Test de détection automatique de `game_profile`
  - [ ] Scénarios métiers complets et jeu avec client connecté

## Phase 1 : Amélioration de l'IA et des comportements (v1.0)

### Objectif
Rendre les villageois plus intelligents et autonomes dans leurs décisions.

### Fonctionnalités

#### 1.1 Système de besoins
**Priorité : Haute**

Les villageois ont des besoins qui influencent leur comportement :
- **Faim** : Nécessité de manger régulièrement
- **Repos** : Besoin de sommeil la nuit
- **Outils** : Besoin d'outils appropriés pour leur métier
- **Matériaux** : Besoin de matériaux pour travailler

*Statut : implémenté (module `working_villagers/needs.lua`, suivi/decay exécuté dans `on_step`).*

**Implémentation** :
```lua
-- Nouveau fichier : working_villagers/needs.lua
working_villages.needs = {
    hunger = { max = 100, decay_rate = 0.1 },
    energy = { max = 100, decay_rate = 0.05 },
    -- ...
}
```

**Bénéfices** :
- Comportements plus réalistes
- Meilleure priorisation des tâches
- Interactions plus variées

#### 1.2 Système de décision intelligent
**Priorité : Haute**

Améliorer la prise de décision avec un système de priorités :
- Évaluation de multiples tâches possibles
- Choix basé sur les besoins et compétences
- Adaptation selon le contexte

**Implémentation** :
```lua
-- Fichier : working_villagers/ai_decision.lua
ai_decision.apply(self)
-- Score les besoins (faim, énergie, outils, matériaux) et pose un hint d'action prioritaire
```

*Statut : en place (évaluation des besoins + hints d'action, non bloquant).*

#### 1.3 Mémoire et apprentissage
**Priorité : Moyenne**

Les villageois se souviennent :
- Des positions de ressources fréquentes
- Des chemins efficaces
- Des zones dangereuses
- De leurs interactions passées

**Implémentation** :
```lua
-- Extension de storage.lua
working_villages.memory = {
    resource_locations = {},
    frequent_paths = {},
    danger_zones = {},
}
```

*Statut : implémenté (module `working_villagers/memory.lua`, sérialisation dans `api.lua`, nettoyage périodique dans `on_step`).*
*Ajout : HUD permanent (besoins + apprentissages) et workflow d'autorisations pour expérimentations/édition de plans. Corrigé le 27/09/2026 (alpha.8) : les barres de besoins étaient invisibles depuis leur introduction (texture transparente colorisée) ; le HUD montre désormais des barres colorées lisibles, le nom/métier du villageois suivi et un résumé de village en secours.*

### Livrables Phase 1
- [x] Module de gestion des besoins
- [x] Système de décision par priorité (hints basés sur besoins)
- [x] Mémoire persistante des villageois
- [x] HUD apprentissage + demandes d'autorisation
- [ ] Documentation API étendue
- [ ] Tests de comportement

## Phase 2 : Interactions et collaboration (v1.5)

### Objectif
Permettre aux villageois de travailler ensemble et de communiquer.

### Fonctionnalités

#### 2.1 Système de communication
**Priorité : Haute**

Les villageois peuvent :
- Demander de l'aide à d'autres villageois
- Partager des informations sur les ressources
- Coordonner les tâches
- Alerter en cas de danger

**Implémentation** :
```lua
-- Nouveau fichier : working_villagers/communication.lua
function communication.send_message(from, to, message_type, data)
    -- Messages types :
    -- "help_needed", "resource_found", "danger_alert", "task_complete"
end
```

**Exemples d'usage** :
- Miner trouve du minerai → alerte le blacksmith
- Builder manque de matériaux → demande au woodcutter
- Guard voit un danger → alerte tous les villageois

*Statut : implémenté (communication.lua + messages miner/builder/guard, HUD affiche le compteur).*

#### 2.2 Travail collaboratif
**Priorité : Haute**

Certaines tâches nécessitent plusieurs villageois :
- Construction de grands bâtiments
- Défrichage de zones étendues
- Projets de village complexes

**Implémentation** :
```lua
-- Nouveau fichier : working_villagers/collaborative_tasks.lua
function collaborative_tasks.register_task(name, definition)
    -- definition contient :
    -- - required_jobs : quels métiers sont nécessaires
    -- - min_villagers : nombre minimum
    -- - task_logic : comment répartir le travail
end
```

*Statut : implémenté (collaborative_tasks.lua + tâches large_building, danger_response, resource_delivery).*

#### 2.3 Structures sociales
**Priorité : Moyenne**

Hiérarchie et organisation du village :
- **Chef de village** : Coordonne les projets
- **Maîtres artisans** : Supervisent leur domaine
- **Apprentis** : Apprennent des experts

**Bénéfices** :
- Meilleure organisation
- Transmission des connaissances
- Progression naturelle des villageois

*Statut : partiel (pilotage du village, focus stratégique et niveau de notifications disponibles ; hiérarchie explicite chef/maîtres/apprentis encore à implémenter).*

### Livrables Phase 2
- [x] Module de communication inter-villageois
- [x] Système de tâches collaboratives
- [x] Au moins 3 tâches collaboratives implémentées
- [ ] Structure sociale basique
- [ ] Tests d'interaction

## Phase 3 : Économie et échanges (v2.0)

### Objectif
Créer une économie fonctionnelle dans les villages.

### Fonctionnalités

#### 3.1 Système monétaire
**Priorité : Moyenne**

Introduction d'une monnaie :
- Villageois gagnent de l'argent en travaillant
- Peuvent acheter des ressources
- Échangent entre eux

**Implémentation** :
```lua
-- Extension de storage.lua
function villager:get_money()
function villager:add_money(amount)
function villager:can_afford(cost)
```

#### 3.2 Commerce et échanges
**Priorité : Moyenne**

- Marché du village
- Échanges villageois ↔ joueur
- Échanges entre villageois
- Système d'offre et demande

#### 3.3 Spécialisation économique
**Priorité : Basse**

Villages spécialisés :
- Village minier
- Village agricole
- Village commercial
- Commerce entre villages

### Livrables Phase 3
- [ ] Système monétaire
- [ ] Interface de commerce
- [ ] Au moins 5 types d'échanges
- [ ] Équilibrage économique
- [ ] Documentation du système économique

## Phase 4 : Construction autonome (v2.5)

### Objectif
Les villageois construisent et développent leur village de manière autonome.

### Fonctionnalités

#### 4.1 Planification de village
**Priorité : Haute**

Le système décide quoi construire :
- Évalue les besoins du village
- Choisit les blueprints appropriés
- Positionne les bâtiments intelligemment
- Coordonne la construction

**Implémentation** :
```lua
-- Nouveau fichier : working_villagers/village_planning.lua
function village_planning.evaluate_needs(village_data)
    -- Retourne liste de bâtiments prioritaires
end

function village_planning.find_build_location(blueprint, village_center)
    -- Trouve le meilleur emplacement
end
```

*Statut : partiellement implémenté dans le builder autonome (évaluation simple de l'état du village, choix de blueprint, ordre de chantier forcé par le joueur), mais le module dédié reste à extraire et formaliser.*

#### 4.2 Gestion des ressources
**Priorité : Haute**

- Inventaire collectif du village
- Stockage centralisé
- Distribution automatique des ressources
- Priorisation selon les besoins

#### 4.3 Évolution du village
**Priorité : Moyenne**

Villages qui grandissent naturellement :
- Niveaux de village (hameau → village → ville)
- Déblocage de nouveaux blueprints
- Plus de villageois avec la croissance
- Infrastructure qui s'améliore

### Livrables Phase 4
- [x] Heuristiques initiales de planification et choix autonome de blueprint
- [ ] Module de planification dédié et isolé
- [x] Registre de stockage partagé et comptabilité ciblée des transferts
- [ ] Distribution autonome des ressources validée de bout en bout
- [ ] Système de niveaux de village
- [ ] Au moins 5 nouveaux blueprints avancés
- [ ] Tests de construction autonome

## Phase 5 : Défense et aventure (v3.0)

### Objectif
Ajouter des éléments de défi et d'aventure.

### Fonctionnalités

#### 5.1 Système de défense amélioré
**Priorité : Moyenne**

- Détection de menaces avancée
- Coordination des guards
- Système d'alarme du village
- Fortifications automatiques

#### 5.2 Événements de village
**Priorité : Basse**

- Festivals et célébrations
- Visites de marchands
- Attaques de monstres
- Quêtes pour les joueurs

#### 5.3 Relations inter-villages
**Priorité : Basse**

- Alliance entre villages
- Commerce longue distance
- Guerres de territoire (optionnel)
- Système de réputation

## Améliorations techniques continues

### Performances
**Priorité : Constante**

- [ ] Optimisation du pathfinding
- [ ] Réduction de la charge sur le serveur
- [ ] Mise en cache des calculs coûteux
- [ ] Profiling et mesures de performance

### Code quality
**Priorité : Constante**

- [ ] Refactorisation continue
- [ ] Réduction de la dette technique
- [ ] Tests automatisés
- [ ] Documentation à jour

### Compatibilité
**Priorité : Constante**

- [ ] Support des nouveaux mods populaires
- [ ] API stable et versionnée
- [ ] Migrations de données entre versions
- [ ] Backward compatibility

## Fonctionnalités communautaires

### API publique
**Priorité : Haute**

Permettre aux autres mods d'interagir :
```lua
-- API pour autres mods
working_villages.api.register_job_extension(name, def)
working_villages.api.register_village_event(name, def)
working_villages.api.register_blueprint_type(name, def)
```

### Hooks et callbacks
**Priorité : Moyenne**

Points d'extension pour personnalisation :
- `on_villager_spawn`
- `on_job_change`
- `on_blueprint_learned`
- `on_building_complete`
- `on_village_level_up`

### Configuration avancée
**Priorité : Moyenne**

Paramètres pour ajuster le gameplay :
- Vitesse de progression
- Difficulté de survie des villageois
- Fréquence des besoins
- Coûts économiques

## Métriques de succès

### Phase 1
- Villageois prennent des décisions logiques 90% du temps
- Pas de comportements incohérents observés
- Performance stable avec 20+ villageois

### Phase 2
- Villageois communiquent entre eux visiblement
- Au moins 3 exemples de collaboration réussie
- Structure sociale reconnaissable

### Phase 3
- Économie équilibrée et fonctionnelle
- Échanges fréquents et variés
- Valeur des objets cohérente

### Phase 4
- Villages construits autonomement sont jouables
- Planification intelligente et adaptée
- Croissance naturelle observable

### Phase 5
- Villages se défendent efficacement
- Événements intéressants et variés
- Relations entre villages fonctionnelles

## Étapes de stabilisation

### Compatibilité des jeux
- [x] Centraliser les mappings dans `compat/vl.lua` et retirer les principales branches locales `if mcl_core` des jobs
- [x] Charger le mod sur serveur headless avec les profils VoxeLibre et Minetest Game
- [ ] Refaire le test VoxeLibre sur une installation intacte, sans correctif local de métadonnées du jeu
- [ ] Compléter la documentation des mappings et limites propres aux métiers
- [ ] Jouer les scénarios farmer/builder/miner/blacksmith/cook dans chaque jeu avec un client connecté

### Release 0.11 : IA et besoins (beta)
- [x] Prototyper `needs.lua` (faim/énergie/outils) et brancher la décroissance de stats sur le tick IA
- [x] Activer `ai_decision.lua` dans la boucle de vie des villageois avec hints d'action
- [ ] Ajouter des compteurs de perf (ticks IA, appels pathfinding) pour mesurer l'impact

### Release 0.12 : stabilisation serveurs
- [ ] Profiling charge (serveur dédié VoxeLibre) et plan d'optimisation cible (pathfinding, caches)
- [x] Pack de tests automatisés ciblés et définition de workflow présents
- [ ] Observer une exécution CI réelle de ces tests et ajouter des régressions de cycles métiers
- [ ] Notes de release et checklist migration pour les mondes existants

### Release 0.13 : stabilisation du village autonome
- [x] Spawn initial avec recherche de surface et persistance vérifiée en headless
- [ ] `/wv_spawn5` validé manuellement dans les deux modes d'autorisation
- [x] Rapport du village, priorités stratégiques et ordre de chantier via dialogues
- [x] Commandes forgeron et nettoyage de chantiers invalides
- [x] Moteur de craft partagé et comptabilité ciblée des transferts/objets exacts
- [x] Redéfinition du coffre partagé et logique de pose autonome du premier coffre
- [x] Séquence de bootstrap villageois utilisée par l'auto-affectation, l'autonome et le builder, avec builder en soutien logistique avant construction
- [x] Rapport du village enrichi avec phase bootstrap, état du coffre commun et totaux disponibles
- [x] Contrôle persistant et coordination intelligente pour les villages `self_employed` via le sceptre de commande
- [x] Logiques de survie d'urgence, four du forgeron/cuisinier et auto-configuration de maison présentes dans le code
- [x] Nettoyage des branches bruyantes builder/miner avec gestion explicite des positions inaccessibles et attentes d'inventaire/matériaux
- [x] Plan de culture persistant (`uniform`/`rows`) et replantation fidèle à la culture récoltée
- [x] Recherche déterministe d'un terrain plat, sec, accessible et non protégé sur toute l'emprise du plan
- [x] Dégagement explicite du volume intérieur et réservation immédiate du chantier par son constructeur
- [x] Harnais physique ciblé alpha.7 réussi dans les deux profils pour semis déterministe, refus du premier terrain invalide et dégagement intérieur réel
- [x] Harnais strict de village complet à cinq PNJ, comptabilité globale et reprise en deux phases créé
- [x] Progression v12 observée en monde VoxeLibre neuf jusqu'à cinq PNJ stables
  au moins 273 s, coffre, cinq outils, 31 arbres, maturité et une récolte
- [x] Échecs diagnostiques v17 et v18 consignés sans les présenter comme des
  validations terminales
- [ ] Exécuter v19 et obtenir un verdict terminal reproductible
- [ ] Verdict terminal de ce harnais dans les deux profils
- [ ] Session graphique réelle de 30 à 60 minutes dans chaque jeu, puis
  validation manuelle complète de ces flux et de l'économie autonome de bout
  en bout (protocole dans `VALIDATION_CHECKLIST.md`)

## Nouveau metier : marchand (working_villages:job_trader)

Note de conception ajoutee le 27/09/2026 ; implementee le meme jour, au
niveau code uniquement (voir statut plus bas).

- **Pourquoi celui-la** : `minetest_game` (le jeu par defaut) n'a ni animaux
  ni peche, ce qui elimine berger/pecheur comme choix a parite entre les
  deux jeux cibles.
- **Choix final, plus sur que la conception initiale** : la premiere version
  de cette note envisageait une table d'echanges fixes (bois -> planches,
  etc.) avec une logique de validation atomique ecrite a la main. En la
  concevant, une option strictement plus sure est apparue : au lieu d'ecrire
  du nouveau code de transfert d'inventaire, la page `working_villages:trader_post`
  affiche simplement le vrai coffre commun via les widgets natifs
  `list[]`/`listring[]` de Minetest, exactement comme n'importe quel coffre
  ouvert directement. Le moteur gere alors tout le transfert ; aucune
  logique de duplication/atomicite a auditer n'a ete introduite ici.
- **Garde-fou verifie avant commit** : la page est gardee par
  `requires_manage = true` (comme `inv_gui`/`job_change`/`data_change`) ;
  sans ce garde-fou, n'importe quel joueur aurait pu vider le coffre commun
  d'un village etranger en parlant a un seul de ses villageois.
- **Statut** : code ecrit, relu ligne a ligne a la main (toujours aucun
  interpreteur Lua ni moteur Luanti disponible dans cet environnement
  d'agent), mais **jamais execute**. Aucun `STANDALONE_SPEC_OK` ni test
  moteur ne couvre ce metier pour l'instant ; voir [JOBS.md](JOBS.md) pour
  le detail.

## Contributions

Nous accueillons les contributions sur tous ces aspects. Consultez [CONTRIBUTING.md](CONTRIBUTING.md) pour commencer.

### Priorités pour les contributeurs

**Facile** (bon pour débuter) :
- Nouveaux blueprints
- Textures et sons
- Documentation
- Tests de bugs

**Moyen** :
- Nouveaux métiers
- Améliorations de métiers existants
- Optimisations de performance
- Nouvelles interactions

**Difficile** :
- Systèmes d'IA
- Pathfinding avancé
- Planification de village
- Économie

## Calendrier prévisionnel

- **Phase 1** : 2-3 mois
- **Phase 2** : 3-4 mois
- **Phase 3** : 2-3 mois
- **Phase 4** : 4-6 mois
- **Phase 5** : 3-4 mois

**Total estimé** : 14-20 mois pour atteindre la v3.0

Le développement est itératif et les priorités peuvent changer selon les retours de la communauté.

## Feedback

Vos retours sont essentiels ! Partagez vos idées :
- GitHub Issues : Suggestions et bugs
- Forum Minetest : Discussions générales
- Pull Requests : Contributions directes

---

*Dernière mise à jour : 2026-09-27*
*Version du document : 1.3*
