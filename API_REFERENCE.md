# API Reference - working_villages

Ce document fournit une référence complète de l'API du mod working_villages pour les développeurs.

## Table des matières

1. [Enregistrement de villageois](#enregistrement-de-villageois)
2. [Enregistrement de jobs](#enregistrement-de-jobs)
3. [API des villageois](#api-des-villageois)
4. [Système de blueprints](#système-de-blueprints)
5. [Patterns de jobs](#patterns-de-jobs)
6. [Système de comportement IA](#système-de-comportement-ia)
7. [Nouveaux modules depuis alpha 1](#nouveaux-modules-depuis-alpha-1)
8. [Compatibilité VoxeLibre](#compatibilité-voxelibre)

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

Incrémente un timer nommé en pas logiques historiques. Pendant `on_step`, le
temps moteur est normalisé selon `working_villages_timer_step_seconds` (0,1 s
par défaut), ce qui conserve le rythme des métiers indépendamment du FPS
serveur. Un seuil de 20 représente donc environ 2 secondes avec le réglage par
défaut.

**Paramètres:**
- `name` (string): Nom du timer

#### self:timer_exceeded(name, threshold)

Vérifie si un timer a dépassé un seuil et le réinitialise.

**Paramètres:**
- `name` (string): Nom du timer
- `threshold` (number): Seuil en pas logiques

**Retour:** `boolean` - `true` si dépassé

**Exemple:**
```lua
self:count_timer("search")
if self:timer_exceeded("search", 20) then
    -- Environ toutes les 2 secondes avec le réglage par défaut
end
```

#### self:seconds_exceeded(name, seconds)

Vérifie et réinitialise un timer à partir d'une durée exprimée explicitement
en secondes. Utiliser cette variante pour les réglages utilisateur documentés
en secondes ; conserver `timer_exceeded` pour les seuils historiques des
métiers.

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

### working_villages.blueprints.register(name, definition)

Enregistre un nouveau blueprint.

**Paramètres:**
- `name` (string): Nom unique du blueprint
- `definition` (table): Définition du blueprint

**Structure de définition:**
```lua
{
    description = string,
    category = working_villages.blueprints.CATEGORY.HOUSE,
    difficulty = working_villages.blueprints.DIFFICULTY.BEGINNER,
    nodes = {                       -- Liste de nœuds, facultative si schematic_file est fourni
        {pos = {x = 0, y = 0, z = 0}, node = {name = "default:stone", param2 = 0}},
        -- ...
    },
    schematic_file = string,        -- Fichier .we facultatif
    improvements = {},              -- Améliorations facultatives
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

### working_villages.blueprints.has_learned(inv_name, blueprint_name)

Vérifie si un villageois a déjà appris un blueprint.

**Paramètres:**
- `inv_name` (string): Nom de l'inventaire
- `blueprint_name` (string): Nom du blueprint

**Retour:** `boolean` - `true` si le blueprint est déjà appris

Il n'existe pas de fonction `can_learn`. Pour connaître les plans actuellement
accessibles, utiliser `working_villages.blueprints.get_available_to_learn(inv_name)`
et vérifier la présence de `blueprint_name` dans la table retournée. Pour tenter
l'apprentissage et obtenir une raison en cas d'échec, utiliser :

```lua
local success, message = working_villages.blueprints.teach(inv_name, blueprint_name)
```

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

## Nouveaux modules depuis alpha 1

Modules introduits après la rédaction initiale de ce document. Voir
ARCHITECTURE.md pour une vue d'ensemble de chacun et AUDIT_STATUS.md pour
leur niveau de preuve (code / test autonome / test moteur / test manuel) ;
cette section ne documente que les fonctions qu'un auteur de nouveau
métier appelle le plus couramment, pas l'intégralité de chaque module.

### Besoins (`working_villages.needs`)

#### needs.get(self, name)
Lit la jauge d'un besoin.

**Paramètres:**
- `self` (villager)
- `name` (string): `"hunger"`, `"energy"`, `"tools"` ou `"materials"`

**Retour:** `number` - Valeur entre 0 et 100 (100 si non initialisé)

#### needs.set(self, name, value) / needs.adjust(self, name, delta)
Fixe ou ajuste une jauge (bornée automatiquement entre 0 et 100).

#### needs.get_low(self)
**Retour:** `table` - Liste (non triée) des besoins sous leur seuil bas ou
critique parmi ceux marqués exploitables par la config (`cfg.decision ~=
false`). Chaque entrée : `{name, level, value}` avec `level` valant
`"low"` ou `"critical"`.

### Accès aux inventaires de nœuds (`working_villages.inventory_access`)

Utilisé par la quasi-totalité des métiers pour parler à un coffre, un four
ou un établi pour le compte d'un villageois. Toutes ces fonctions
vérifient la protection avant d'agir et échouent fermé (refusent) en cas
d'erreur plutôt que de laisser passer.

#### inventory_access.put_stack(self, pos, listname, stack, preferred_index)
Dépose `stack` dans la liste `listname` du nœud à `pos`.

**Retour:** `remaining (ItemStack), moved (number)` - `remaining` est ce
qui n'a **pas** pu être déposé (jamais perdu, à conserver par l'appelant) ;
`moved` est la quantité réellement déposée.

#### inventory_access.take_stack(self, pos, listname, index, maximum)
Retire jusqu'à `maximum` objets de l'emplacement `index`.

**Retour:** `taken (ItemStack), taken_count (number)`

#### inventory_access.take_to_inventory / put_from_inventory
Variantes qui transfèrent directement vers/depuis une autre `InvRef`
(typiquement `self:get_inventory()`) sans repasser par l'inventaire de
l'appelant.

**Exemple:**
```lua
local inventory_access = working_villages.require("inventory_access")
local taken, moved = inventory_access.take_stack(self, chest_pos, "main", 1, 10)
if moved > 0 then
    self:get_inventory():add_item("main", taken)
end
```

### Artisanat partagé (`working_villages.crafting`)

#### crafting.ensure_item(self, itemname, count, opts, ctx)
S'assure que le villageois possède `count` exemplaires de `itemname` dans
son inventaire principal, en le fabriquant récursivement (sous-recettes,
résolution de groupes, établi si nécessaire) si besoin. Échec atomique :
si la fabrication échoue en cours de route, les ressources déjà entamées
sont restaurées plutôt que perdues (sauf avec `opts.use_shared_storage`,
qui étend la transaction au coffre commun).

**Paramètres notables de `opts`:**
- `use_shared_storage` (boolean): autorise à puiser dans le coffre commun
- `fail_cooldown` (number, secondes): délai avant de retenter après un
  échec (défaut 15s)
- `force` (boolean): ignore le cooldown d'échec
- `rollback_local_failure` (boolean, défaut `true`): restaure
  l'inventaire principal si la fabrication échoue en cours de route ;
  désactivé automatiquement quand `use_shared_storage` est vrai, car la
  transaction dépasse alors l'inventaire local

Le 5e paramètre `ctx` (optionnel, distinct de `opts`) contrôle la
récursion : `ctx.max_depth` limite la profondeur de sous-recettes
(défaut 4). Note verifiee en ecrivant cette section : passer `max_depth`
**dans `opts`** (comme le fait un appel existant dans `blacksmith.lua`)
n'a aucun effet, `ensure_any_item` ne transmet jamais de `ctx` a
`ensure_item` ; seul un vrai 5e argument `ctx` fonctionne.

**Retour:** `success (boolean), result (table)` - `result` détaille les
objets manquants si `success` est `false`.

#### crafting.ensure_any_item(self, candidates, count, opts)
Comme `ensure_item`, mais essaie chaque nom de `candidates` dans l'ordre
et s'arrête au premier qui aboutit (utilisé pour les paliers d'outils
bois/pierre/fer par exemple). Ne prend pas de `ctx` : chaque candidat
repart avec une profondeur de recursion fraiche.

### Communication et tâches collaboratives

#### communication.send_message(from, to, message_type, data) / communication.broadcast(from, targets, message_type, data)
Envoie un message à un villageois précis ou à une liste de cibles.
`message_type` est une chaîne libre (`"help_needed"`, `"resource_found"`,
`"danger_alert"`, ...) ; les messages reçus s'accumulent dans la boîte de
réception du destinataire jusqu'à `communication.consume_messages(self)`.

#### communication.find_nearby_villagers(pos, radius, filter_job, owner_name)
**Retour:** `table` - Villageois chargés dans `radius`, filtrés par métier
et/ou propriétaire si précisés.

#### tasks.start_task(name, initiator, data) (`working_villages.collaborative_tasks`)
Démarre une tâche collaborative persistante enregistrée via
`tasks.register_task`. Tâches déjà fournies par le mod :
`resource_delivery`, `food_support`, `mining_tool_supply`,
`danger_response`, `large_building`.

**Retour:** `task_id (string) ou nil, reason (string)`

#### tasks.update(task_id, updates) / tasks.complete(task_id, result) / tasks.fail(task_id, reason)
Font progresser, terminent ou annulent une tâche existante. Les tâches ont
un TTL et sont nettoyées automatiquement (`tasks.cleanup`).

### Contrôle d'accès (`working_villages.access`)

#### access.can_manage_villager(villager, player_or_name)
Vérifie si un joueur peut gérer (donner des ordres à, ouvrir l'inventaire
de) un villageois : vrai pour le propriétaire, un allié explicite, ou un
administrateur avec `protection_bypass` ; faux pour un visiteur, sauf mode
village public explicitement activé.

**Retour:** `allowed (boolean), reason (string ou nil)` - `reason` vaut
par exemple `"not_owner"`, `"self_employed_private"` ou
`"commanding_sceptre_required"`, utilisable pour un message d'erreur
adapté (voir `commanding_sceptre.lua` pour un exemple d'utilisation).

Toute nouvelle page de formulaire qui expose une action sensible (gestion
d'inventaire, accès à un coffre, changement de métier, ...) doit déclarer
`requires_manage = true` lors de `forms.register_page` : c'est le seul
garde-fou qui empêche un joueur quelconque d'agir sur un villageois qui
n'est pas le sien. Deux failles de cette nature ont été trouvées et
corrigées en alpha.8/alpha.9 (voir CHANGELOG.md) sur des pages qui
avaient omis ce champ.

## Compatibilité VoxeLibre

Module `working_villages.voxelibre_compat` pour support multi-jeu.

### working_villages.voxelibre_compat.is_voxelibre

`boolean` - `true` si VoxeLibre est détecté

### working_villages.voxelibre_compat.get_item(item_name)

Obtient le nom d'item approprié pour le jeu actuel.

**Paramètres:**
- `item_name` (string): Identifiant source complet (ex: `"default:torch"`)

**Retour:** `string` - Nom d'item adapté

**Exemple:**
```lua
local torch = compat.get_item("default:torch")
```

### Fonctions utilitaires

- `get_torch_items()` - Retourne `{wall = nom, floor = nom}` pour les deux variantes de torche
- `get_chest_items()` - Retourne la liste des nœuds de coffre reconnus
- `get_door_item()` - Retourne une porte en bois adaptée au profil actif
- `get_door_items()` - Retourne la liste des nœuds de porte reconnus
- `get_bed_items()` - Retourne `{top = {...}, bottom = {...}}` pour les lits reconnus
- `is_door(name)` - Vérifie si le nom correspond à une porte complète
- `bed_meta(name)` - Retourne les métadonnées de paire du lit, ou `nil` si le nom n'est pas reconnu
- `is_bed_top(name)` - Vérifie si le nom correspond à la partie haute d'un lit

Il n'existe pas de fonction générique `is_bed(name)` ni de fonction
`get_bed(color)` dans l'API actuelle.

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
