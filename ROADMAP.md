# Feuille de route - working_villages

## Vision

Transformer les villages de Minetest en communautés vivantes et autonomes où les villageois travaillent, interagissent et construisent ensemble.

## Objectifs à court terme (Version 0.x - Actuelle)

### ✅ Complété

- [x] Système de base des villageois
- [x] Multiples métiers fonctionnels (farmer, builder, woodcutter, etc.)
- [x] Système de blueprints avec apprentissage
- [x] Compatibilité VoxeLibre complète
- [x] Métiers spécialisés (blacksmith, miner)
- [x] Système d'expérience
- [x] Gestion des coffres et inventaires
- [x] Pathfinding fonctionnel
- [x] Protection des zones

### 🔄 En cours

- [ ] Documentation complète de l'API
- [ ] Refactorisation du code dupliqué
- [ ] Amélioration des performances
- [ ] Tests unitaires

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
-- Nouveau fichier : working_villagers/ai_decision.lua
function ai_decision.evaluate_tasks(villager, available_tasks)
    -- Score chaque tâche selon :
    -- - Urgence des besoins
    -- - Distance
    -- - Compétence du villageois
    -- - Priorité du village
end
```

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

### Livrables Phase 1
- [ ] Module de gestion des besoins
- [ ] Système de décision par priorité
- [ ] Mémoire persistante des villageois
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

### Livrables Phase 2
- [ ] Module de communication inter-villageois
- [ ] Système de tâches collaboratives
- [ ] Au moins 3 tâches collaboratives implémentées
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
- [ ] Module de planification
- [ ] Gestion des ressources collectives
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

*Dernière mise à jour : 2025-12-21*
*Version du document : 1.0*
