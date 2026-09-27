# Guide de contribution - working_villages

Merci de votre intérêt pour contribuer à working_villages ! Ce document vous guidera dans le processus de contribution.

## Table des matières

1. [Code de conduite](#code-de-conduite)
2. [Comment contribuer](#comment-contribuer)
3. [Standards de code](#standards-de-code)
4. [Architecture](#architecture)
5. [Tests](#tests)
6. [Processus de Pull Request](#processus-de-pull-request)

## Code de conduite

- Soyez respectueux et courtois envers tous les contributeurs
- Acceptez les critiques constructives
- Concentrez-vous sur ce qui est meilleur pour la communauté
- Faites preuve d'empathie envers les autres membres de la communauté

## Comment contribuer

### Signaler des bugs

Avant de créer un rapport de bug :
- Vérifiez qu'il n'existe pas déjà dans les [Issues](https://github.com/prog66/working_villages/issues)
- Assurez-vous que vous utilisez la dernière version

Pour signaler un bug, créez une issue avec :
- **Titre clair et descriptif**
- **Étapes pour reproduire** le problème
- **Comportement attendu** vs **comportement observé**
- **Version** de Minetest et du mod
- **Environnement** : minetest_game ou VoxeLibre
- **Logs** si pertinents

### Suggérer des fonctionnalités

Pour suggérer une nouvelle fonctionnalité :
- Créez une issue avec le tag `enhancement`
- Décrivez clairement la fonctionnalité et son utilité
- Expliquez comment elle s'intègre dans le mod
- Proposez une implémentation si possible

### Contribuer du code

1. **Fork** le repository
2. **Créez une branche** pour votre fonctionnalité : `git checkout -b feature/ma-fonctionnalite`
3. **Committez** vos changements : `git commit -m 'Ajout de ma fonctionnalité'`
4. **Push** vers la branche : `git push origin feature/ma-fonctionnalite`
5. **Ouvrez une Pull Request**

## Standards de code

### Style Lua

#### Indentation
- Utilisez des **tabulations** (caractère tab), pas des espaces
- Indentation cohérente dans tout le fichier

#### Nommage

```lua
-- Variables locales : snake_case
local my_variable = 10
local player_name = "Steve"

-- Fonctions locales : snake_case
local function calculate_distance(pos1, pos2)
    return vector.distance(pos1, pos2)
end

-- Tables de module : snake_case
working_villages.my_module = {}

-- Méthodes de module : snake_case
function working_villages.my_module.my_function()
    -- ...
end

-- Constantes : UPPER_SNAKE_CASE (si vraiment constantes)
local MAX_DISTANCE = 100
```

#### Structure d'un fichier

```lua
-- 1. Requires au début
local func = working_villages.require("jobs/util")
local compat = working_villages.voxelibre_compat

-- 2. Variables locales
local searching_range = {x = 10, y = 3, z = 10}

-- 3. Fonctions locales utilitaires
local function helper_function(param)
    -- ...
end

-- 4. Logique principale / exports
working_villages.register_job("working_villages:job_example", {
    -- ...
})
```

#### Commentaires

```lua
-- Commentaires sur une ligne pour explications courtes

--[[ 
Commentaires multi-lignes pour :
- Descriptions de sections
- Documentation de fonctions complexes
- Explications détaillées
]]--

-- Documentation des fonctions importantes
-- working_villages.villager.get_inventory returns a inventory of a villager.
function working_villages.villager:get_inventory()
    -- ...
end
```

#### Bonnes pratiques

```lua
-- ✅ BON : Vérification des paramètres
function my_function(param)
    assert(type(param) == "string", "param must be a string")
    -- ...
end

-- ✅ BON : Retours précoces pour plus de clarté
function check_something(value)
    if not value then
        return false
    end
    if value < 0 then
        return false
    end
    return true
end

-- ✅ BON : Utilisation de variables locales
local function process_items(items)
    local result = {}
    for i, item in ipairs(items) do
        result[i] = process_item(item)
    end
    return result
end

-- ❌ ÉVITER : Globales non nécessaires
function bad_function()  -- Devient globale !
    -- ...
end

-- ✅ BON : Fonction locale
local function good_function()
    -- ...
end
```

### Longueur des lignes

- Maximum **240 caractères** (configuré dans `.luacheckrc`)
- Idéalement **80-100 caractères** pour la lisibilité

### Vérification avec luacheck

Avant de committer, exécutez :

```bash
git ls-files -z '*.lua' ':(exclude)working_villagers/modutil/**' \
  | xargs -0 --no-run-if-empty luacheck --config .luacheckrc
```

Cette commande correspond exactement au périmètre du workflow. La configuration
se trouve dans `.luacheckrc`; aucun fichier Lua suivi ne doit être omis.

## Architecture

Consultez [ARCHITECTURE.md](ARCHITECTURE.md) pour comprendre la structure du mod.

### Ajouter un nouveau métier

1. Créez `working_villagers/jobs/mon_metier.lua`
2. Suivez la structure existante :

```lua
local func = working_villages.require("jobs/util")
local blueprints = working_villages.blueprints
local compat = working_villages.voxelibre_compat

-- Fonctions de recherche locales
local function find_target(pos)
    -- Logique de recherche
end

-- Range de recherche
local searching_range = {x = 10, y = 5, z = 10}

-- Enregistrement du métier
working_villages.register_job("working_villages:job_mon_metier", {
    description = "mon métier (working_villages)",
    long_description = "Description détaillée de ce que fait le villageois avec ce métier.",
    inventory_image = "default_paper.png^working_villages_mon_metier.png",
    jobfunc = function(self)
        -- Gestion standard
        self:handle_night()
        self:handle_chest(take_func, put_func)
        self:handle_job_pos()
        
        -- Logique du métier
        self:count_timer("mon_metier:search")
        if self:timer_exceeded("mon_metier:search", 20) then
            -- Recherche et action
            local target = func.search_surrounding(
                self.object:get_pos(), 
                find_target, 
                searching_range
            )
            
            if target then
                -- Navigation et action
                local destination = func.find_adjacent_clear(target)
                if destination then
                    destination = func.find_ground_below(destination)
                    self:go_to(destination)
                end
                -- Action spécifique
                -- ...
                -- Expérience si approprié
                blueprints.add_experience(self:get_inventory_name(), 1)
            end
        end
    end
})
```

3. Ajoutez le require dans `working_villagers/init.lua`
4. Créez une texture dans `working_villagers/textures/`

### Ajouter un nouveau blueprint

```lua
-- Dans blueprints_default.lua ou votre fichier
working_villages.blueprints.register("mon_blueprint", {
    description = "Description du blueprint",
    category = working_villages.blueprints.CATEGORY.HOUSE,
    difficulty = working_villages.blueprints.DIFFICULTY.INTERMEDIATE,
    nodes = {
        {pos = {x = 0, y = 0, z = 0}, node = {name = "default:stone"}},
        -- ...
    },
    -- À la place de nodes, un fichier peut être chargé avec :
    -- schematic_file = "mon_blueprint.we",
    improvements = {},
})
```

### Utiliser la couche de compatibilité

Toujours utiliser le système de compatibilité pour les items :

```lua
local compat = working_villages.voxelibre_compat

-- ✅ BON : Utilise la compatibilité
local torch = compat.get_torch_items().floor
local chest_candidates = compat.get_chest_items()

-- ❌ ÉVITER : Hardcoder les noms
local torch = "default:torch"  -- Ne fonctionne pas avec VoxeLibre !
```

## Tests

### Tests manuels

Avant de soumettre une PR, testez :

1. **Dans minetest_game** :
   - Le métier/fonctionnalité fonctionne
   - Pas d'erreurs dans les logs
   - Interactions avec les coffres/inventaires
   - Pathfinding vers les cibles

2. **Dans VoxeLibre** :
   - Même tests que ci-dessus
   - Vérifier les noms d'items mappés
   - Tester avec les variantes VoxeLibre (ex: différentes couleurs de lits)

3. **Performance** :
   - Avec 1 villageois
   - Avec 10 villageois
   - Avec 20+ villageois
   - Pas de ralentissement notable

### Tests automatisés

Si vous ajoutez des tests :
- Placez-les dans `working_villagers/tests/`
- Nommez-les clairement : `test_mon_module.lua`

## Processus de Pull Request

### Avant de soumettre

- [ ] Le code passe `luacheck` sans erreurs
- [ ] Testé dans minetest_game
- [ ] Testé dans VoxeLibre (si applicable)
- [ ] Documentation mise à jour (si nécessaire)
- [ ] Commits clairs et descriptifs

### Template de PR

```markdown
## Description
Brève description de ce que fait cette PR

## Type de changement
- [ ] Bug fix
- [ ] Nouvelle fonctionnalité
- [ ] Amélioration de fonctionnalité existante
- [ ] Documentation
- [ ] Refactoring

## Tests effectués
- [ ] minetest_game
- [ ] VoxeLibre
- [ ] Performance vérifiée

## Checklist
- [ ] Code passe luacheck
- [ ] Documentation à jour
- [ ] Tests effectués
- [ ] Commits bien nommés
```

### Revue de code

- Soyez patient, les revues peuvent prendre du temps
- Répondez aux commentaires de manière constructive
- Faites les modifications demandées
- Les mainteneurs peuvent demander des changements

### Après la fusion

- Votre contribution sera créditée
- Merci de votre contribution ! 🎉

## Conventions de commit

### Format

```
type(scope): description courte

Description détaillée si nécessaire.

Fixes #123
```

### Types

- `feat`: Nouvelle fonctionnalité
- `fix`: Correction de bug
- `docs`: Documentation seulement
- `style`: Formatage, pas de changement de code
- `refactor`: Refactoring sans changement fonctionnel
- `perf`: Amélioration de performance
- `test`: Ajout de tests
- `chore`: Maintenance, dépendances

### Exemples

```
feat(jobs): ajout du métier de boulanger

Ajoute un nouveau métier de boulanger qui peut :
- Cuisiner du pain
- Utiliser des fours
- Collecter du blé

Fixes #45

---

fix(pathfinder): correction du bug de navigation

Le pathfinder pouvait se bloquer dans certains cas
de terrain complexe. Ajout d'une vérification
supplémentaire.

Fixes #78
```

## Ressources

- [Documentation Minetest Lua API](https://minetest.gitlab.io/minetest/)
- [Forum working_villages](https://forum.minetest.net/viewtopic.php?f=9&t=17429)
- [ARCHITECTURE.md](ARCHITECTURE.md)
- [ROADMAP.md](ROADMAP.md)
- [api.MD](working_villagers/api.MD)

## Questions ?

- Ouvrez une [issue](https://github.com/prog66/working_villages/issues) avec le tag `question`
- Demandez sur le [forum Minetest](https://forum.minetest.net/viewtopic.php?f=9&t=17429)

## Licence

En contribuant, vous acceptez que votre code soit sous licence MIT (voir LICENSE).

---

Merci de contribuer à working_villages ! 🏘️
