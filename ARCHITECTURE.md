# Architecture du mod working_villages

## Vue d'ensemble

Le mod `working_villages` est un système complexe qui permet aux villageois de Minetest d'effectuer diverses tâches de manière autonome. Le mod est conçu de manière modulaire pour faciliter l'ajout de nouvelles fonctionnalités et la maintenance.

## Structure des répertoires

```
working_villages/
└── working_villagers/          # Module principal (seul mod du dépôt)
    ├── jobs/                   # Définitions des métiers
    ├── compat/                 # Couche de compatibilité unifiée (compat/vl.lua)
    ├── tests/                  # Suites de tests autonomes (lua5.1, sans moteur)
    ├── modutil/                # Ancien sous-module Git, non requis à l'exécution
    ├── schems/                 # Schémas de structures (.we)
    └── textures/               # Textures du mod
```

Note : ce dépôt contenait aussi un mod séparé `building_sign/` (marqueurs de
construction/panneaux) ; il a été retiré, sa fonctionnalité étant reprise
par `building.lua`. `modutil/` reste présent comme métadonnée Git
historique mais `loader.lua` charge le mod sans dépendance d'exécution à
ce sous-module (voir README.MD, section "Submodules").

## Composants principaux

### 1. Système de base (Core System)

#### loader.lua
Chargeur local minimal (`working_villages.require(name)`) : résout et
exécute chaque fichier du mod au plus une fois, sans dépendance
d'exécution au sous-module `modutil`. Détecte les cycles de dépendance et
rejette les chemins invalides.

#### log.lua
Journalisation structurée (`log.error`, `log.warning`, ...) utilisée par
la plupart des modules récents à la place d'appels `minetest.log` bruts.

#### init.lua
Point d'entrée du mod. Charge tous les modules dans le bon ordre via
`working_villages.require` :
1. `loader.lua` + `log.lua`
2. `village_registry.lua`
3. Compatibilité (VoxeLibre/minetest_game), besoins/mémoire/décision/permissions
4. Formulaires, logement, stockage, population, plans de construction
5. API de base des villageois + artisanat + enregistrement des villageois
6. Métiers spécialisés puis métier autonome
7. `spawn.lua`

#### needs.lua, ai_decision.lua, memory.lua
Trois modules de la Phase 1 de la feuille de route :
- `needs.lua` : jauges faim/énergie/outils/matériaux par villageois,
  décroissance dans `on_step`, et politique pure de choix/rotation des
  métiers spécialistes (garde, forgeron, cuisinier) selon l'état du
  village.
- `ai_decision.lua` : évalue les besoins et pose un indice d'action
  prioritaire (non bloquant) sur le villageois.
- `memory.lua` : mémoire persistante (emplacements de ressources, chemins
  fréquents, zones dangereuses), sérialisée via `api.lua` et nettoyée
  périodiquement.

#### village_registry.lua, population.lua
- `village_registry.lua` : identité persistante de village (propriétaire,
  centre, rayon), pensée comme index central à terme ; contrats testés
  dans `tests/village_registry_spec.lua`.
- `population.lua` : registre léger des villageois vivants par village
  (comptage, snapshot, checkpoint/reprise après redémarrage).

#### access.lua, permissions.lua
- `access.lua` : contrôle d'accès central (propriétaire, allié explicite,
  visiteur refusé, village public via sceptre, administrateur) utilisé par
  les formulaires, l'inventaire et les actions sensibles.
- `permissions.lua` : file de demandes d'autorisation (ex : sauvegarde
  d'un plan expérimental) avec auto-acceptation temporisée configurable.

#### communication.lua, collaborative_tasks.lua
- `communication.lua` : messages inter-villageois (`help_needed`,
  `resource_found`, `danger_alert`, ...).
- `collaborative_tasks.lua` : tâches persistantes à plusieurs
  participants (`resource_delivery`, `food_support`,
  `mining_tool_supply`, `danger_response`, `large_building`), avec TTL,
  états terminaux et nettoyage automatique.

#### survival.lua
Survie orientée serveur public : PV doublés par défaut, dégâts calculés
avant le mécanisme fatal du moteur, réduction d'armure/bouclier,
protection temporaire après spawn/rechargement, régénération lente sans
danger, dégâts joueurs limités au propriétaire par défaut
(configurable), seuil de fuite à mi-vie.

#### crafting.lua, economy_recipes.lua
- `crafting.lua` : moteur de craft partagé (recettes enregistrées,
  sous-recettes, résolution de groupes d'items, comptabilité atomique du
  coffre commun).
- `economy_recipes.lua` : recettes agricoles directes (botte de paille,
  lit, pain plat) enregistrées selon le profil de jeu détecté.

#### hud.lua
HUD persistant par joueur : besoins et métier du villageois suivi le plus
proche, ou résumé du village (population par métier) à défaut. Voir
`README.MD` (section Quick start) pour la description côté joueur.

#### inventory_access.lua
Couche d'accès aux inventaires de nœuds (coffres, fours, établis) pour le
compte d'un villageois : vérifie la protection avant chaque opération,
échoue fermé en cas d'erreur, et fournit `put_stack`/`take_stack`/
`put_from_inventory`/`take_to_inventory`/`can_access` utilisés par la
plupart des métiers.

#### construction_planner.lua, crop_planner.lua, blueprint_experiments.lua
- `construction_planner.lua` : validation déterministe d'un terrain de
  chantier (emprise complète, sol, liquides, protections, obstacles,
  accès), calcul de boîte englobante (`get_bounds`), préparation des
  cellules d'air à dégager.
- `crop_planner.lua` : plan de culture persistant (modes `uniform`,
  `rows`, `available`), indépendant de l'ordre de ramassage des piles.
- `blueprint_experiments.lua` : propositions d'expérimentation sur un
  plan appris (ex. remplacement de matériaux), soumises à autorisation
  via `permissions.lua`.

#### timers.lua, work_fallback.lua
- `timers.lua` : timers basés sur le temps moteur (indépendants du FPS
  serveur) utilisés par les coroutines de métiers.
- `work_fallback.lua` : comportement d'attente/repli partagé quand un
  métier ne peut pas progresser immédiatement (ramassage à proximité,
  patrouille visible plutôt qu'immobilité).

#### api.lua
Définit l'API principale pour les villageois :
- `working_villages.villager` : Classe de base pour tous les villageois
- `working_villages.registered_villagers` : Table des types de villageois
- `working_villages.registered_jobs` : Table des métiers disponibles
- Système de suivi des positions échouées (failed_pos_*)

**Fonctions clés** :
- `villager:get_inventory()` : Accès à l'inventaire
- `villager:get_job_name()` : Récupération du métier actuel
- `villager:change_job()` : Changement de métier
- `villager:get_nearest()` : Recherche du villageois le plus proche

### 2. Système de compatibilité

#### voxelibre_compat.lua et compat/vl.lua
Couche d'abstraction pour supporter à la fois minetest_game et VoxeLibre :
- Détection automatique de l'environnement de jeu
- Mapping des noms d'items (default:* ↔ mcl_core:*)
- Mapping des portes (doors:* ↔ mcl_doors:*)
- Mapping des coffres, fours, torches, lits, outils, armures, boucliers, etc.

`compat/vl.lua` centralise les mappings et est chargé après
`voxelibre_compat.lua` (qu'il `require`) ; en cas de définition présente
dans les deux fichiers, celle de `compat/vl.lua` gagne toujours. Des
fallbacks directs `default:*`/`mcl_*` subsistent malgré tout dans quelques
métiers (garde, mineur, bûcheron) ; la centralisation complète reste un
chantier ouvert (voir ROADMAP.md).

#### farming_compat.lua
Abstraction spécifique pour les systèmes agricoles :
- Support du mod `farming` (minetest_game)
- Support du mod `mcl_farming` (VoxeLibre)
- Détection des stades de croissance
- Gestion de la récolte et replantation

### 3. Système d'état des villageois

#### villager_state.lua
Gestion de l'état et des comportements des villageois :
- `set_pause(state)` : Mettre en pause/reprendre
- `set_displayed_action(action)` : Afficher l'action en cours
- `set_state_info(text)` : Information détaillée de l'état

#### async_actions.lua
Actions asynchrones pour les villageois :
- Navigation et déplacement
- Interaction avec les nœuds
- Gestion du pathfinding asynchrone

### 4. Système de pathfinding

#### pathfinder.lua
Algorithme de recherche de chemin A* adapté :
- Calcul de chemins entre deux points
- Prise en compte des obstacles
- Support de la montée/descente
- Optimisations pour les performances

**Fonctions principales** :
- `pathfinder.find_path(from, to)` : Trouve un chemin
- `pathfinder.search_surrounding(pos, condition, range)` : Recherche dans les environs

### 5. Système de jobs

#### jobs/util.lua
Utilitaires communs à tous les métiers :
- `search_surrounding(pos, condition, range)` : Recherche de positions
- `find_adjacent_clear(pos)` : Trouver un espace adjacent libre
- `find_ground_below(pos)` : Trouver le sol en dessous

#### Structure d'un job

Chaque métier est défini avec :
```lua
working_villages.register_job("working_villages:job_NAME", {
    description = "Description courte",
    long_description = "Description détaillée du comportement",
    inventory_image = "texture.png",
    jobfunc = function(self)
        -- Logique du métier
    end
})
```

**Métiers disponibles** (14, tous chargés depuis `init.lua`) :
- **autonomous** : bootstrap du village, collecte polyvalente, exploration
- **builder** : Construction de bâtiments
- **farmer** : Agriculture (récolte et replantation)
- **woodcutter** : Coupe d'arbres et replantation
- **blacksmith** : Travail du métal et réparation d'outils
- **miner** : Minage de pierre et minerais
- **cook** : Cuisine via un vrai four, comptabilité du coffre commun
- **trader** : Tient le poste de troc (fenêtre à distance sur le coffre
  commun via son menu de discussion) ; ne récolte ni ne construit rien
- **plant_collector** : Collection de plantes
- **guard** : Protection du village
- **learner/apprenant** : Mode apprentissage pour un villageois sans métier
- **follow_player** : Suivi d'un joueur
- **torcher** : Placement de torches
- **snowclearer** : Nettoyage de la neige (métier de test)

Le groupe initial de spawn (5 PNJ) est fixe : woodcutter, farmer,
autonomous, miner, builder. Voir JOBS.md pour le détail par métier et
AUDIT_STATUS.md pour le niveau de preuve de chacun.

### 6. Système de blueprints

#### blueprints.lua
Système d'apprentissage et de gestion des plans de construction :
- Enregistrement de nouveaux blueprints
- Système d'expérience pour les villageois
- Apprentissage progressif des plans
- Amélioration des plans existants
- Sauvegarde persistante

**Catégories de blueprints** :
- House : Habitations
- Farm : Fermes
- Workshop : Ateliers
- Infrastructure : Infrastructures
- Decoration : Décorations

#### blueprints_default.lua
Plans de construction par défaut :
- simple_house, fancy_house, minimal_house, minimal_shelter
- farm_plot
- workshop, blacksmith_forge
- mine_entrance, town_square, watchtower, castle_fortress
- garden

#### blueprint_construction.lua
Utilitaires pour la construction à partir de blueprints :
- Génération des données de construction
- Calcul des matériaux nécessaires
- Suggestions d'apprentissage
- Gestion des améliorations

#### blueprint_forms.lua
Interface utilisateur pour les blueprints :
- Vue d'ensemble des blueprints appris
- Interface d'apprentissage
- Interface d'amélioration

### 7. Système de construction

#### building.lua
Gestion des marqueurs de construction et des bâtiments :
- `buildings.register(name, definition)` : Enregistrer un type de bâtiment
- `buildings.get(pos)` : Récupérer un bâtiment
- `buildings.find_beds(nodedata)` : Trouver les lits dans un bâtiment
- Gestion des portes et des lits

> Note : `working_villagers/building_sign.lua` (deux lignes, distinct du
> mod `building_sign/` retiré) reste dans le dépôt mais n'est chargé par
> aucun `require` de `init.lua` ; il appelle un global `building_sign`
> jamais défini et erreurait s'il était exécuté. Code mort à supprimer,
> pas une fonctionnalité active.

### 8. Système d'interface

#### forms.lua
Système de formulaires pour l'interface utilisateur :
- Formulaires enregistrables (`forms.register_page`)
- Gestion des callbacks (`receiver`), avec contrôle d'accès `requires_manage`
- Navigation entre formulaires, y compris un menu générique
  (`forms.register_menu_page`) utilisé par le menu de discussion
- Entrées de menu conditionnelles : `forms.put_link(source, target,
  description, visible_fn)` accepte un `visible_fn(villager)` optionnel ;
  une entrée masquée pour ce villageois n'apparaît simplement pas dans la
  liste (ex. "Configurer le garde" n'apparaît que pour un garde). Ajouté en
  alpha.9 pour éviter d'afficher des options sans rapport avec le métier
  du villageois parlé.

#### commanding_sceptre.lua
Outil de commande des villageois :
- Clic gauche : Mettre en pause
- Clic droit : Ouvrir l'inventaire
- Accès aux formulaires (jobs, blueprints, etc.)

### 9. Système de stockage

#### storage.lua
Persistance des données :
- Sauvegarde automatique toutes les 5 minutes
- Données par villageois
- Données globales du mod

Ce mécanisme historique reste utilisé en parallèle des stockages plus
récents et spécialisés (`village_registry.lua`, `population.lua`,
`collaborative_tasks.lua`, coffre partagé) plutôt que remplacé par eux ;
`village_registry.lua` est pensé comme futur index central mais n'est pas
encore la source unique de vérité.

### 10. Utilitaires

#### util.lua
Fonctions utilitaires générales :
- Voisins euclidiens
- Itération sur des offsets
- Opérations vectorielles

#### groups.lua
Définition des groupes Minetest pour le mod.

#### failures.lua
Gestion des échecs et tentatives :
- Suivi des positions où les actions ont échoué
- Évite les tentatives répétées inutiles
- Nettoyage automatique après expiration

## Flux de travail d'un villageois

1. **Initialisation** : Le villageois est créé avec un métier
2. **Boucle principale** (`jobfunc`) :
   - Gestion de la nuit (retour à la maison)
   - Interaction avec les coffres
   - Recherche de tâches à effectuer
   - Navigation vers la cible
   - Exécution de l'action
   - Mise à jour de l'état et de l'expérience
3. **Événements** :
   - Changement de métier
   - Apprentissage de blueprints
   - Interactions avec le joueur

## Système d'expérience

Les villageois gagnent de l'expérience en effectuant des tâches :

| Métier | Action | Expérience |
|--------|--------|------------|
| Builder | Compléter un bâtiment | 5 XP |
| Farmer | Récolter une plante | 1 XP |
| Woodcutter | Couper un arbre | 1 XP |
| Woodcutter | Planter un arbre | 1 XP |
| Blacksmith | Réparer un outil | 1 XP |
| Miner | Miner un bloc | 1 XP |

L'expérience permet :
- D'apprendre de nouveaux blueprints
- D'améliorer les blueprints existants
- De débloquer des capacités avancées (futur)

## Système de timers

Les villageois utilisent des timers en pas logiques pour espacer leurs actions.
Le pas vaut 0,1 seconde par défaut et est calculé depuis `dtime`, donc le rythme
reste indépendant du FPS serveur :
```lua
self:count_timer("job:action")
if self:timer_exceeded("job:action", 20) then
    -- Action environ toutes les 2 secondes avec le pas par défaut
end
```

Timers communs :
- `search` : Recherche de cibles (20 pas logiques)
- `change_dir` : Changement de direction (60 pas logiques)
- `chest_search` : Recherche de coffres (40 pas logiques)

Les options documentées en secondes utilisent `self:seconds_exceeded(...)`.

## Gestion de la protection

Tous les métiers vérifient la protection des zones :
```lua
if minetest.is_protected(pos, "") then
    return false
end
```

Cela garantit que les villageois ne peuvent pas modifier des zones protégées par d'autres joueurs.

## Extensibilité

### Ajouter un nouveau métier

1. Créer un fichier `working_villagers/jobs/mon_metier.lua`
2. Utiliser `working_villages.register_job()`
3. Implémenter la fonction `jobfunc`
4. Ajouter le require dans `init.lua`

### Ajouter un nouveau blueprint

1. Utiliser `working_villages.blueprints.register()`
2. Définir la catégorie, la difficulté et la description
3. Fournir `nodes` ou un `schematic_file`, puis les améliorations éventuelles

### Ajouter une nouvelle compatibilité

1. Modifier `voxelibre_compat.lua`
2. Ajouter les mappings nécessaires
3. Tester dans les deux environnements

## Points d'amélioration identifiés

### Code à refactoriser

1. **api.lua** : Devrait être divisé en modules plus petits
2. **Jobs dupliqués** : Extraction des patterns communs (gestion des coffres, recherche)
3. **Pathfinder** : Optimisations possibles pour les grandes distances
4. **TODOs** : Plusieurs TODOs à traiter (voir grep "TODO" dans le code)

### Déjà implémenté depuis la version initiale de ce document

Cette liste était à l'origine une liste de souhaits ; les points suivants
ont depuis un module dédié (code présent, niveau de preuve variable —
voir AUDIT_STATUS.md) :
- **Besoins** : `needs.lua` (faim, énergie, outils, matériaux)
- **Communication** : `communication.lua` (messages inter-villageois)
- **IA collaborative** : `collaborative_tasks.lua` (tâches à plusieurs
  participants)
- **Mémoire/apprentissage** : `memory.lua`, métier `learner`
- **Début d'économie** : `crafting.lua`, `economy_recipes.lua`, coffre
  commun partagé, métier `trader` ; pas encore de monnaie ni d'échanges
  entre villageois eux-mêmes

### Améliorations futures restantes

1. **Planification de village dédiée** : un module isolé de planification
   (actuellement des heuristiques dans le builder autonome)
2. **Économie complète** : monnaie, échanges villageois ↔ villageois
3. **Spécialisation** : arbres de compétences par métier
4. **Structure sociale explicite** : hiérarchie chef/maîtres/apprentis
5. **Niveaux de village** : croissance hameau → village → ville

## Dépendances

### Obligatoires
Aucune. `loader.lua` charge le mod sans dépendance d'exécution à
`modutil` ; le seul prérequis est l'un des deux jeux supportés
(minetest_game ou VoxeLibre), détecté automatiquement.

### Optionnelles (minetest_game)
- `default` : Blocs de base
- `doors` : Portes
- `beds` : Lits
- `farming` : Agriculture

### Optionnelles (VoxeLibre)
- `mcl_core` : Blocs de base
- `mcl_doors` : Portes
- `mcl_beds` : Lits
- `mcl_chests` : Coffres
- `mcl_farming` : Agriculture
- `mcl_torches` : Torches

## Tests et validation

### Tests automatisés existants

- `working_villagers/tests/` : 23 spécifications autonomes (`*_spec.lua`)
  qui tournent sous `lua5.1` avec un environnement `minetest`/`working_villages`
  simulé, sans moteur réel. Lancement individuel :
  `lua5.1 working_villagers/tests/needs_spec.lua working_villagers`.
- `.github/workflows/standalone-tests.yml` : exécute ces specs en CI
  (à l'exclusion de `compat_spec.lua` et `ore_smelting_spec.lua`, qui ont
  besoin d'un vrai moteur).
- `.github/workflows/luacheck.yml` : lint statique.
- `test_harness/` : mondes Luanti jetables et mods de test pour des
  scénarios moteur réels (spawn, four, portes, livraison physique, etc.),
  décrits dans `test_harness/README.md`.

Voir AUDIT_STATUS.md pour la matrice complète preuve-par-fonctionnalité
(code / test autonome / test moteur / test manuel) et pour ce qui n'a
**pas** encore de preuve d'exécution du tout.

### Tests manuels recommandés
- Tester chaque métier dans les deux environnements
- Vérifier la compatibilité des blueprints
- Tester les interactions coffre/inventaire
- Vérifier le pathfinding dans différents terrains

Protocole détaillé dans `VALIDATION_CHECKLIST.md`.

### Linting
Le projet utilise `luacheck` pour la vérification du code :
```bash
luacheck working_villagers/
```

Configuration dans `.luacheckrc`.

## Performance

### Optimisations existantes
- Suivi des positions échouées (évite les tentatives répétées)
- Timers pour espacer les recherches
- Nettoyage périodique des données temporaires
- Pathfinding avec limite de profondeur

### Considérations
- Limiter le nombre de villageois actifs simultanément
- Ajuster les ranges de recherche selon les performances
- Utiliser les timers pour réduire la fréquence des calculs coûteux

## License

MIT License (voir LICENSE pour détails)

Exceptions pour certaines textures et portions de code (voir README.MD)
