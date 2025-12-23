# API Reference - working_villages

Ce document fournit une référence complète de l'API du mod working_villages pour les développeurs.

## Table des matières

1. [Enregistrement de villageois](#enregistrement-de-villageois)
2. [Enregistrement de jobs](#enregistrement-de-jobs)
3. [API des villageois](#api-des-villageois)
4. [Système de blueprints](#système-de-blueprints)
5. [Patterns de jobs](#patterns-de-jobs)
6. [Système de comportement IA](#système-de-comportement-ia)
7. [Compatibilité VoxeLibre](#compatibilité-voxelibre)

## Enregistrement de villageois

### working_villages.register_villager(name, definition)

Enregistre un nouveau type de villageois.

**Paramètres:**
- `name` (string): Nom unique du villageois (ex: "working_villages:male_villager")
- `definition` (table): Définition de l'entité avec propriétés Minetest standard

**Propriétés importantes de definition:**
- `hp_max` (number): Points de vie maximum
- `weight` (number): Poids pour la gravité
- `mesh` (string): Fichier de modèle 3D (ex: "character.b3d")
- `textures` (table): Liste de textures à appliquer au modèle
- `egg_image` (string): Texture de l'œuf de spawn

**Exemple:**
```lua
working_villages.register_villager("mymod:custom_villager", {
    hp_max = 20,
    weight = 20,
    mesh = "character.b3d",
    textures = {"my_texture.png"},
    egg_image = "my_egg.png"
})
```

### Modèle 3D et Squelette

Les villageois utilisent le modèle `character.b3d` qui est fourni par:
- **minetest_game**: mod `default`
- **VoxeLibre**: mod `mcl_player`

**Structure du squelette (bones):**
- `Body`: Torse principal
- `Head`: Tête (pour mouvements de tête)
- `Arm_Left` et `Arm_Right`: Bras (pour animations de bras)
- `Leg_Left` et `Leg_Right`: Jambes (pour animation de marche)

**Frames d'animation disponibles:**
```lua
working_villages.animation_frames = {
  STAND     = { x=  0, y= 79, },  -- Immobile
  LAY       = { x=162, y=166, },  -- Couché (dormir)
  WALK      = { x=168, y=187, },  -- Marche
  MINE      = { x=189, y=198, },  -- Miner/travailler
  WALK_MINE = { x=200, y=219, },  -- Marcher en portant
  SIT       = { x= 81, y=160, },  -- Assis
}
```

**Textures:**
- Format minetest_game: 64x32 pixels (traditionnel)
- Format VoxeLibre: 64x64 pixels (compatible Minecraft)
- Les deux formats fonctionnent dans les deux jeux

**Pour obtenir le modèle approprié selon le jeu:**
```lua
local voxelibre_compat = working_villages.voxelibre_compat
local player_mesh = voxelibre_compat.get_player_mesh()  -- Retourne "character.b3d"
```

## Enregistrement de jobs

### working_villages.register_job(name, definition)

Enregistre un nouveau métier pour les villageois.

**Paramètres:**
- `name` (string): Nom unique du job (ex: "working_villages:job_farmer")
- `definition` (table): Définition du job

**Structure de definition:**
```lua
{
    description = string,           -- Description courte
    long_description = string,      -- Description détaillée (affichée aux joueurs)
    inventory_image = string,       -- Texture de l'item du job
    jobfunc = function(self)        -- Fonction exécutée chaque tick
}
```

**Exemple:**
```lua
working_villages.register_job("mymod:job_baker", {
    description = "baker (mymod)",
    long_description = "I bake bread and other goods for the village.",
    inventory_image = "mymod_baker.png",
    jobfunc = function(self)
        self:handle_night()
        -- Logique du métier...
    end
})
```

## API des villageois

Méthodes disponibles sur les objets villageois (via `self` dans jobfunc).

### Inventaire

#### self:get_inventory()

Retourne l'inventaire détaché du villageois.

**Retour:** `InvRef`

**Exemple:**
```lua
local inv = self:get_inventory()
local stack = inv:get_stack("main", 1)
```

#### self:get_inventory_name()

Retourne le nom de l'inventaire du villageois.

**Retour:** `string`

### Armure

Les villageois peuvent équiper des armures dans 4 emplacements : tête, torse, jambes, et pieds. L'armure est affichée visuellement sur le villageois en utilisant des entités PNG attachées aux os du squelette. Compatible avec minetest_game (3d_armor) et VoxeLibre (mcl_armor).

#### self:get_armor_stack(slot)

Obtient l'objet d'armure dans un emplacement spécifique.

**Paramètres:**
- `slot` (string): Nom de l'emplacement ("head", "torso", "legs", ou "feet")

**Retour:** `ItemStack` - L'armure dans cet emplacement

**Exemple:**
```lua
local helmet = self:get_armor_stack("head")
if not helmet:is_empty() then
    minetest.log("Villager wearing: " .. helmet:get_name())
end
```

#### self:set_armor_stack(slot, stack)

Définit l'objet d'armure dans un emplacement spécifique.

**Paramètres:**
- `slot` (string): Nom de l'emplacement ("head", "torso", "legs", ou "feet")
- `stack` (ItemStack): L'armure à équiper

**Exemple:**
```lua
-- Équiper un casque en acier
self:set_armor_stack("head", ItemStack("3d_armor:helmet_steel"))
```

#### self:get_head_item_stack()

Obtient le casque/armure de tête. Raccourci pour `get_armor_stack("head")`.

**Retour:** `ItemStack`

#### self:set_head_item_stack(stack)

Définit le casque/armure de tête. Raccourci pour `set_armor_stack("head", stack)`.

**Paramètres:**
- `stack` (ItemStack): Le casque à équiper

**Notes sur l'armure:**
- L'armure est affichée via des entités PNG attachées aux os du modèle
- Les emplacements acceptent uniquement les objets avec les groupes appropriés :
  - `armor_head` pour l'emplacement tête
  - `armor_torso` pour l'emplacement torse
  - `armor_legs` pour l'emplacement jambes
  - `armor_feet` pour l'emplacement pieds
- Compatible avec les deux systèmes d'armure (minetest_game et VoxeLibre)

### Jobs

#### self:get_job_name()

Retourne le nom du job actuel.

**Retour:** `string` - Nom du job (ex: "working_villages:job_farmer")

#### self:get_job()

Retourne la définition complète du job actuel.

**Retour:** `table` - Définition du job ou `nil`

#### self:change_job(job_name)

Change le métier du villageois.

**Paramètres:**
- `job_name` (string): Nom du nouveau job

### État et animation

#### self:set_pause(paused)

Met en pause ou reprend le villageois.

**Paramètres:**
- `paused` (boolean): `true` pour pause, `false` pour reprendre

**Exemple:**
```lua
self:set_pause(true)  -- Pause le villageois
```

#### self:set_displayed_action(action)

Définit le texte d'action affiché aux joueurs.

**Paramètres:**
- `action` (string): Action en cours (ex: "working", "idle")

**Exemple:**
```lua
self:set_displayed_action("farming")
```

#### self:set_state_info(text)

Définit l'information détaillée de l'état (pour debugging/interface).

**Paramètres:**
- `text` (string): Description détaillée de l'état actuel

**Exemple:**
```lua
self:set_state_info("Searching for crops to harvest in a 10 block radius.")
```

#### self:set_animation(frames)

Change l'animation du villageois.

**Paramètres:**
- `frames` (table): Frame range de l'animation (ex: `working_villages.animation_frames.WALK`)

**Animations disponibles:**
- `working_villages.animation_frames.STAND`
- `working_villages.animation_frames.WALK`
- `working_villages.animation_frames.MINE`
- `working_villages.animation_frames.WALK_MINE`
- `working_villages.animation_frames.LAY` (dormir)
- `working_villages.animation_frames.SIT`

### Navigation

#### self:go_to(pos)

Navigue vers une position.

**Paramètres:**
- `pos` (table): Position cible `{x, y, z}`

**Exemple:**
```lua
self:go_to({x=10, y=5, z=20})
```

#### self:get_nearest_player(range, pos)

Trouve le joueur le plus proche.

**Paramètres:**
- `range` (number): Distance maximale de recherche
- `pos` (table, optionnel): Position depuis laquelle chercher

**Retour:** `ObjectRef, table, number` - Joueur, position, distance ou `nil`

### Timers

#### self:count_timer(name)

Incrémente un timer nommé.

**Paramètres:**
- `name` (string): Nom du timer

#### self:timer_exceeded(name, threshold)

Vérifie si un timer a dépassé un seuil et le réinitialise.

**Paramètres:**
- `name` (string): Nom du timer
- `threshold` (number): Seuil en ticks

**Retour:** `boolean` - `true` si dépassé

**Exemple:**
```lua
self:count_timer("search")
if self:timer_exceeded("search", 20) then
    -- Effectuer une recherche toutes les 20 ticks
end
```

### Gestion standard

#### self:handle_night()

Gère le retour à la maison la nuit (si home_pos est défini).

**Exemple:**
```lua
function jobfunc(self)
    self:handle_night()  -- Toujours appeler en premier
    -- reste de la logique...
end
```

#### self:handle_chest(take_func, put_func)

Gère l'interaction avec les coffres à proximité.

**Paramètres:**
- `take_func` (function): `function(self, stack) -> boolean` - Retourne `true` pour prendre l'item
- `put_func` (function): `function(self, stack) -> boolean` - Retourne `true` pour stocker l'item

**Exemple:**
```lua
local function take_tools(self, stack)
    return minetest.get_item_group(stack:get_name(), "pickaxe") > 0
end

local function store_resources(self, stack)
    return minetest.get_item_group(stack:get_name(), "pickaxe") == 0
end

self:handle_chest(take_tools, store_resources)
```

#### self:handle_job_pos()

Gère la position de travail assignée.

#### self:handle_obstacles()

Gère les obstacles et évite de rester bloqué.

## Système de blueprints

### working_villages.blueprints.register_blueprint(name, definition)

Enregistre un nouveau blueprint.

**Paramètres:**
- `name` (string): Nom unique du blueprint
- `definition` (table): Définition du blueprint

**Structure de definition:**
```lua
{
    display_name = string,          -- Nom affiché
    description = string,           -- Description
    category = string,              -- "House", "Farm", "Workshop", "Infrastructure", "Decoration"
    difficulty = number,            -- 1-5 (Beginner à Master)
    structure = {
        size = {x, y, z},           -- Taille de la structure
        center_offset = {x, y, z},  -- Offset du centre
        nodes = {                   -- Liste des nodes
            {pos = {x, y, z}, node = {name = string, param2 = number}},
            -- ...
        }
    }
}
```

### working_villages.blueprints.add_experience(inv_name, amount)

Ajoute de l'expérience à un villageois.

**Paramètres:**
- `inv_name` (string): Nom de l'inventaire du villageois
- `amount` (number): Quantité d'expérience à ajouter

**Exemple:**
```lua
working_villages.blueprints.add_experience(self:get_inventory_name(), 5)
```

### working_villages.blueprints.get_experience(inv_name)

Récupère l'expérience d'un villageois.

**Paramètres:**
- `inv_name` (string): Nom de l'inventaire

**Retour:** `number` - Quantité d'expérience

### working_villages.blueprints.can_learn(inv_name, blueprint_name)

Vérifie si un villageois peut apprendre un blueprint.

**Paramètres:**
- `inv_name` (string): Nom de l'inventaire
- `blueprint_name` (string): Nom du blueprint

**Retour:** `boolean, string` - Peut apprendre, raison si non

## Patterns de jobs

Module `working_villages.job_patterns` fournissant des patterns réutilisables.

### Gestionnaires de coffres

#### job_patterns.chest_handlers.create_put_func(filter_groups)

Crée une fonction put_func pour les coffres.

**Paramètres:**
- `filter_groups` (table): Liste des groupes d'items à garder

**Retour:** `function` - Fonction compatible avec handle_chest

**Exemple:**
```lua
local put_func = job_patterns.chest_handlers.create_put_func({"axe", "pickaxe"})
```

#### job_patterns.chest_handlers.create_take_func(filter_groups)

Crée une fonction take_func (inverse de put_func).

**Paramètres:**
- `filter_groups` (table): Liste des groupes à prendre des coffres

**Retour:** `function`

### Recherche et action

#### job_patterns.search_and_act.execute(self, options)

Pattern standard de recherche-navigation-action.

**Paramètres:**
- `self` (table): Objet villageois
- `options` (table): Configuration

**Options:**
```lua
{
    timer_name = string,                        -- Nom du timer
    timer_threshold = number,                   -- Seuil du timer (défaut: 20)
    find_func = function(pos) -> boolean,       -- Fonction de recherche
    search_range = {x, y, z},                   -- Portée de recherche
    action_func = function(self, pos),          -- Action à effectuer
    no_target_message = string,                 -- Message si pas de cible
    working_message = string                    -- Message si cible trouvée
}
```

**Exemple:**
```lua
job_patterns.search_and_act.execute(self, {
    timer_name = "miner:search",
    find_func = find_stone,
    search_range = {x=10, y=5, z=10},
    action_func = function(self, pos)
        -- Miner le bloc
    end,
    no_target_message = "Looking for stone.",
    working_message = "Mining stone."
})
```

### Expérience

#### job_patterns.experience.award(self, amount, message)

Donne de l'expérience avec message optionnel.

**Paramètres:**
- `self` (table): Objet villageois
- `amount` (number): Quantité d'XP
- `message` (string, optionnel): Message à afficher

### Sécurité

#### job_patterns.safety.is_safe(pos, extra_checks)

Vérifie si une position est sûre pour interagir.

**Paramètres:**
- `pos` (table): Position à vérifier
- `extra_checks` (function, optionnel): Vérifications supplémentaires

**Retour:** `boolean` - `true` si sûre

### Outils

#### job_patterns.tools.has_tool(self, tool_group)

Vérifie si le villageois a un outil.

**Paramètres:**
- `self` (table): Objet villageois
- `tool_group` (string): Groupe d'outil (ex: "pickaxe")

**Retour:** `boolean`

#### job_patterns.tools.find_tool(self, tool_group)

Trouve un outil dans l'inventaire.

**Paramètres:**
- `self` (table): Objet villageois
- `tool_group` (string): Groupe d'outil

**Retour:** `ItemStack, number` - Stack de l'outil et index, ou `nil`

## Système de comportement IA

Module `working_villages.ai_behavior` pour IA avancée.

### Priorités de tâches

```lua
ai_behavior.PRIORITY = {
    CRITICAL = 100,  -- Critique
    URGENT = 75,     -- Urgent
    HIGH = 50,       -- Élevé
    NORMAL = 25,     -- Normal
    LOW = 10,        -- Bas
}
```

### Machine à états

#### ai_behavior.state_machine.set_state(self, state, data)

Définit l'état du villageois.

**Paramètres:**
- `self` (table): Objet villageois
- `state` (string): Nouvel état
- `data` (table, optionnel): Données d'état

**États communs:**
```lua
ai_behavior.STATES = {
    IDLE = "idle",
    WORKING = "working",
    TRAVELING = "traveling",
    RESTING = "resting",
    EMERGENCY = "emergency",
}
```

#### ai_behavior.state_machine.get_state(self)

Récupère l'état actuel.

**Retour:** `string` - État actuel

#### ai_behavior.state_machine.get_state_duration(self)

Durée dans l'état actuel.

**Retour:** `number` - Temps en secondes

### Système de mémoire

#### ai_behavior.memory.remember_location(self, category, pos, data)

Mémorise un emplacement.

**Paramètres:**
- `self` (table): Objet villageois
- `category` (string): Catégorie (ex: "resource", "danger")
- `pos` (table): Position à mémoriser
- `data` (table, optionnel): Données associées

**Exemple:**
```lua
ai_behavior.memory.remember_location(self, "resource", tree_pos, {type = "oak"})
```

#### ai_behavior.memory.recall_locations(self, category, max_age)

Récupère les emplacements mémorisés.

**Paramètres:**
- `self` (table): Objet villageois
- `category` (string): Catégorie à récupérer
- `max_age` (number, optionnel): Âge maximum en secondes

**Retour:** `table` - Liste d'entrées de mémoire

### Sélection de tâches

#### ai_behavior.task_priority.select_best_task(self, tasks)

Sélectionne la meilleure tâche parmi une liste.

**Paramètres:**
- `self` (table): Objet villageois
- `tasks` (table): Liste de définitions de tâches

**Structure de tâche:**
```lua
{
    name = string,                              -- Nom de la tâche
    priority = number,                          -- Priorité de base
    condition = function(self) -> boolean,      -- Peut être exécutée?
    evaluate = function(self, base) -> number,  -- Ajuste la priorité
    execute = function(self) -> boolean,        -- Exécute la tâche
}
```

**Retour:** `table` - Meilleure tâche ou `nil`

## Compatibilité VoxeLibre

Module `working_villages.voxelibre_compat` pour support multi-jeu.

### working_villages.voxelibre_compat.is_voxelibre

`boolean` - `true` si VoxeLibre est détecté

### working_villages.voxelibre_compat.get_item(item_name)

Obtient le nom d'item approprié pour le jeu actuel.

**Paramètres:**
- `item_name` (string): Nom de base (ex: "torch")

**Retour:** `string` - Nom d'item adapté

**Exemple:**
```lua
local torch = compat.get_torch()  -- "default:torch" ou "mcl_torches:torch"
```

### Fonctions utilitaires

- `get_torch()` - Obtient l'item torche
- `get_chest()` - Obtient l'item coffre
- `get_door(type)` - Obtient un type de porte
- `get_bed(color)` - Obtient un lit (avec couleur pour VoxeLibre)
- `is_door(name)` - Vérifie si c'est une porte
- `is_bed(name)` - Vérifie si c'est un lit

## Positions échouées

### working_villages.failed_pos_record(pos)

Enregistre une position comme échouée (3 minutes).

**Paramètres:**
- `pos` (table): Position à marquer

### working_villages.failed_pos_test(pos)

Teste si une position est marquée comme échouée.

**Paramètres:**
- `pos` (table): Position à tester

**Retour:** `boolean` - `true` si échouée

## Exemples complets

Voir les fichiers suivants pour des exemples complets:
- `jobs/EXAMPLE_enhanced_plant_collector.lua` - Job avec IA avancée
- `jobs/farmer.lua` - Job simple avec patterns
- `jobs/miner.lua` - Job avec gestion d'outils
- `jobs/builder.lua` - Job avec blueprints

---

*Dernière mise à jour : 2025-12-21*
*Version : 1.0*
