# Architecture du mod working_villages

## Vue d'ensemble

Le mod `working_villages` est un système complexe qui permet aux villageois de Minetest d'effectuer diverses tâches de manière autonome. Le mod est conçu de manière modulaire pour faciliter l'ajout de nouvelles fonctionnalités et la maintenance.

## Structure des répertoires

```
working_villages/
├── working_villagers/          # Module principal
│   ├── jobs/                   # Définitions des métiers
│   ├── modutil/                # Sous-module d'utilitaires
│   ├── schems/                 # Schémas de structures
│   └── textures/               # Textures du mod
└── building_sign/              # Module des marqueurs de construction
```

## Composants principaux

### 1. Système de base (Core System)

#### init.lua
Point d'entrée du mod. Charge tous les modules dans le bon ordre :
1. Compatibilité (VoxeLibre/minetest_game)
2. Groupes et formes
3. Systèmes de gestion (storage, buildings, blueprints)
4. API de base
5. Métiers des villageois

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

#### voxelibre_compat.lua
Couche d'abstraction pour supporter à la fois minetest_game et VoxeLibre :
- Détection automatique de l'environnement de jeu
- Mapping des noms d'items (default:* ↔ mcl_core:*)
- Mapping des portes (doors:* ↔ mcl_doors:*)
- Mapping des coffres, torches, lits, etc.

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

**Métiers disponibles** :
- **builder** : Construction de bâtiments
- **farmer** : Agriculture (récolte et replantation)
- **woodcutter** : Coupe d'arbres et replantation
- **blacksmith** : Travail du métal et réparation d'outils
- **miner** : Minage de pierre et minerais
- **plant_collector** : Collection de plantes
- **guard** : Protection du village
- **follow_player** : Suivi d'un joueur
- **torcher** : Placement de torches
- **snowclearer** : Nettoyage de la neige

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
- simple_house, fancy_house
- farm_plot
- workshop, blacksmith_forge
- town_square, watchtower
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

#### building_sign.lua
Interface pour les marqueurs de construction :
- Création de marqueurs
- Formspecs pour la configuration
- Gestion de l'état de construction

### 8. Système d'interface

#### forms.lua
Système de formulaires pour l'interface utilisateur :
- Formulaires enregistrables
- Gestion des callbacks
- Navigation entre formulaires

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

Les villageois utilisent des timers pour espacer leurs actions :
```lua
self:count_timer("job:action")
if self:timer_exceeded("job:action", 20) then
    -- Action à effectuer tous les 20 ticks
end
```

Timers communs :
- `search` : Recherche de cibles (20 ticks)
- `change_dir` : Changement de direction (60 ticks)
- `chest_search` : Recherche de coffres (40 ticks)

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

1. Utiliser `working_villages.blueprints.register_blueprint()`
2. Définir la structure, difficulté, catégorie
3. Ajouter les données de construction

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

### Améliorations futures

1. **IA collaborative** : Villageois travaillant ensemble
2. **Planification de village** : Construction coordonnée
3. **Économie** : Échange entre villageois
4. **Spécialisation** : Arbres de compétences par métier
5. **Communication** : Messages entre villageois
6. **Besoins** : Système de faim, repos, bonheur

## Dépendances

### Obligatoires
- `modutil` (ou sous-module portable inclus)

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

### Tests manuels recommandés
- Tester chaque métier dans les deux environnements
- Vérifier la compatibilité des blueprints
- Tester les interactions coffre/inventaire
- Vérifier le pathfinding dans différents terrains

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
