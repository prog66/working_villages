# Audit factuel et statut de validation

Relevé mis à jour le 27 septembre 2026 (`2026-09-27`) dans
`C:\Users\yanne\Desktop\working_villages`. La section précédente de ce
document datait du 27 août par erreur d'en-tête alors que son contenu
(alpha.7, run v12/v17-v19) était déjà celui du 27 septembre ; seul l'en-tête
a été corrigé ici, le contenu technique n'a pas changé.

## Verdict actuel

**Le mod n'est pas encore démontré prêt à jouer.** Le dépôt contient désormais
une base importante pour l'autonomie, la persistance, l'économie de survie, les
permissions et la compatibilité. Des serveurs Luanti réels ont chargé et
rechargé le snapshot sous les deux profils et des cycles métier ciblés ont été
exercés avec de vraies entités, mais aucun client humain ni partie manuelle
complète n'a été utilisé. Les preuves VoxeLibre emploient une
copie isolée ajustée et l'installation locale 0.92.1 après la même correction
de dépendance ; les preuves Minetest
Game emploient le dépôt officiel au commit
`c42e4d0c0ff9d27ff7b9b308c3cfc14098dd3a0f`. Les harnais couvrent notamment le
spawn persistant, le logement, les callbacks de four, les portes, une livraison
physique mobile et des cycles ciblés bûcheron/fermier/mineur. Le run strict v12
conserve cinq PNJ au moins 273 secondes et progresse jusqu'au coffre, à cinq
outils, à 31 arbres, à des cultures mûres et à une récolte. Il ne couvre
toujours pas, dans ce même scénario, le minerai/dépôt, le four, le chantier, le
redémarrage ni la boucle économique complète.
Les essais v17 et v18 sont restés des échecs diagnostiques sans verdict
terminal ; v19 est préparé mais n'a pas encore été exécuté.

Niveaux de preuve employés ci-dessous :

- **Code** : présence et lecture statique d'une implémentation ; ce n'est pas
  une preuve de comportement.
- **Test autonome** : script Lua pur ou faux environnement Luanti.
- **Test moteur** : serveur Luanti réel et monde jetable, sans joueur humain.
- **Test manuel** : action réellement jouée et observée dans le client.

Un tiret signifie qu'aucune preuve de ce niveau n'est disponible.

## Matrice des phases

| Phase / fonctionnalité | Preuve dans le code | Test autonome présent | Test moteur observé | Test manuel | Statut factuel |
|---|---|---|---|---|---|
| 0 — inventaire du dépôt | `mod.conf`, `depends.txt`, `init.lua`, état Git, modules et suppressions relevés dans ce document | — | — | — | Audit statique réalisé ; dépôt fortement sale, provenance de chaque modification non attribuable automatiquement |
| 0 — flux complet | Modules spawn, besoins, métiers, craft, four, construction, logements et garde reliés statiquement | — | Run v12, monde VoxeLibre neuf : cinq PNJ stables au moins 273 s, coffre, cinq outils, 31 arbres, semis, maturité, une récolte et échanges physiques | — | Progression réelle observée ; minerai/dépôt, four, chantier et redémarrage non confirmés dans v12 ; v17/v18 sont des échecs diagnostiques et v19 n'est pas exécuté, donc aucun verdict terminal |
| 1 — chargeur autonome | `loader.lua` remplace l'appel d'exécution à `modutil` et rejette les chemins invalides/cycles | `startup_spec.lua` | Chargeur traversé dans VoxeLibre isolé | — | Bon niveau de preuve automatisée ; `modutil` reste déclaré comme sous-module Git historique |
| 1 — profil de jeu | `compat/vl.lua` et `voxelibre_compat.lua` détectent `mcl_core` ou `default`, sinon erreur explicite | Assertions de profil et de mappings dans `compat_spec.lua` | Profils VoxeLibre et Minetest Game détectés dans des serveurs réels | — | Détection/mappings de base validés automatiquement dans les deux jeux ; métiers complets non validés |
| 1 — spawn initial persistant | État à cinq emplacements, propriétaire, ancre, retries et marqueur legacy dans `spawn.lua` / `spawn_state.lua` | Contrats purs dans `startup_spec.lua` ; priorité propriétaire configuré/join/force testée | Dans chaque jeu : `created:5`, puis `reloaded:5`, mêmes identités et aucun nouveau spawn | — | Validé automatiquement dans deux mondes headless à propriétaire fixe ; vrai joueur et partie interactive non testés |
| 1 — fichiers, mappings et recettes essentiels | Chargement déterministe, dépendances optionnelles et mappings centralisés ; douze plans par défaut et six recettes directes enregistrés | Assertions moteur dans le harnais / `compat_spec.lua` | Création puis rechargement du harnais principal et `ORE_SMELTING_RECIPES_OK:<profil>` dans les deux jeux, zéro erreur critique | — | Chargement et recettes minerai automatisés validés sur MTG officiel et VoxeLibre isolé ajusté ; procédure interactive non exécutée |
| 1 — procédure d'installation | `INSTALLATION.md`, `DEPLOYMENT.md` et scripts à manifeste | — | Alpha.7 empaquetée, manifeste vérifié et archive extraite chargée dans les deux profils ; alpha.4 installée antérieurement | — | Paquet alpha.7 validé localement mais non installé ; dernier déploiement réellement observé : alpha.4 |
| 2 — groupe initial contrôlé | Cinq rôles initiaux : bûcheron, fermier, autonome, mineur, constructeur ; plafond et rayon configurables | Helpers d'état et `population_spec.lua` ; harnais spawn | Dans les deux jeux : cinq entités, les cinq métiers attendus, aucune nouvelle identité au rechargement | — | Validé sous moteur en mondes jetables ; comportements de travail non validés |
| 2 — coupe et récolte | Bûcheron, collecteur, mineur et actions asynchrones utilisent outils, protection, usure et `node_dig` | Harnais ciblés de conservation | Vrais bûcheron et mineur : outil, coupe/extraction, déplacement, dépôt exact ; replantation du bûcheron dans les deux profils | — | Cycles ciblés validés ; endurance et boucle continue non démontrées |
| 2 — coffre partagé | Coffres isolés par propriétaire ; l'autonome fabrique et pose l'infrastructure | Comptabilité du bootstrap | Le run v12 a créé le coffre commun et journalisé des dépôts/retraits physiques par plusieurs PNJ | — | Bootstrap et échanges réels observés ; propriété multijoueur et reprise complète encore ouvertes |
| 2 — nourriture et agriculture durable | Fermier récolte, laboure et replante avec de vraies graines ; le plan de culture persiste en mode uniforme ou rangées déterministes | Bornes des plans jardin/ferme et `crop_planner_spec.lua` | Dans les deux jeux, un vrai fermier disposant de deux graines en consomme trois d'un seul type planifié ; les anciens harnais prouvent aussi graine naturelle, labour et semis | — | Choix aléatoire de culture corrigé et semis physique ciblé validé ; nourriture et boucle continue récolte/replantation/dépôt non démontrées |
| 2 — établi et four | Le craft VoxeLibre exige un établi pour les recettes dépassant 2×2 ; autonome, cuisinier et forgeron peuvent préparer une zone de four | `crafting_spec.lua` couvre consommation, recette et échec atomique | Le vrai four de chaque jeu a accepté deux transferts avec callbacks et compte exact | — | Contrats de craft/four validés ; aucune création autonome d'atelier et aucun cycle de chauffe complet observés |
| 2 — cuisine | Le cuisinier utilise l'inventaire d'un vrai four en survie ; cuisson instantanée limitée à `creative_test` | — | Module chargé seulement | — | Pas de cuisson réellement observée |
| 2 — outils, mine, fonte et équipement | Besoins mesurés, mineur, catalogue du forgeron, vrai four et consommation de matériau de réparation | `needs_spec.lua` et `miner_wood_bootstrap_spec.lua` couvrent choix et amorçage exact | Vrai mineur : pioche en bois fabriquée, minerai extrait après trajet puis déposé exactement dans les deux profils | — | Mine ciblée validée ; chaîne minerai → lingot → outil/armure non jouée |
| 2 — construction liée aux ressources | Constructeur consomme les piles en survie, valide toute l'emprise, réserve son chantier et dégage l'intérieur avant la structure | `construction_planner_spec.lua`, bornes de plans et contrats de craft | Dans les deux jeux, terrain humide/occupé refusé puis végétation intérieure réellement retirée avec registre avancé ; vraie porte posée et consommée exactement une fois | — | Sélection sûre et préparation physique ciblées validées ; aucun bâtiment complet avec bilan de stock avant/après |
| 2 — progression par stocks | Étapes de bootstrap, jauges mesurées et réaffectation prudente des rôles dans `needs.lua` / `api.lua` | `needs_spec.lua` | Suite isolée passée dans le runtime Lua de Luanti | — | Politique testée, mais aucune progression autonome complète |
| 2 — absence de duplication | Les principaux métiers passent par inventaires et actions réelles ; raccourcis gratuits conditionnés au mode test | Contrats exacts mineur, livraison et sécurité forgeron/constructeur | Bilans ciblés exacts pour bois, mine, livraison, porte et four | — | Plusieurs frontières critiques sont couvertes ; absence de duplication non prouvée globalement |
| 3 — faim | Besoin prioritaire, recherche et consommation de vraie nourriture | Tests de helpers génériques | — | — | Pas de PNJ affamé observé |
| 3 — énergie et repos | Recherche/attribution de logement, récupération au lit ou abri, danger prioritaire | — | Le repli sans abri d'un vrai mineur est exercé par le harnais moteur alpha.4 dans les deux profils | — | Fuite moteur ciblée validée ; aucun cycle jour/nuit ni repos/récupération sans logement observé en partie |
| 3 — logement valide | Marqueur avec vrai lit, accès/porte, sol praticable, propriétaire et lit non partagé ; état stocké | Contrats intégrés au harnais principal | `HOME_VALIDATION_SPEC_OK` sous VoxeLibre et Minetest Game avec vrais nœuds | — | Validation structurelle automatisée ; attribution/rechargement après une vraie construction autonome non exercés |
| 3 — danger et défense | Détection, messages, gardes et réponse collaborative ; équipement gratuit désactivé en survie | Cycle de tâche générique seulement | `C_CALLBACK_ASYNC_GUARDS_OK` dans le harnais principal et `EMERGENCY_RETREAT_RUNTIME_OK:<profil>` dans le harnais moteur alpha.4 | — | Le vrai `on_step` d'un mineur fuit un hostile de test sans `yield` à travers la frontière C ; combat contre les mobs natifs, intervention réelle des gardes, cibles protégées et remplacement d'équipement restent non démontrés |
| 4 — moteur de tâches collaboratives | ID persistant, propriétaire, participants, rôles, données, progression, états terminaux, TTL et nettoyage | `collaborative_tasks_spec.lua` | Suite isolée passée dans Luanti, plus création/restauration/complétion synthétiques du harnais | — | Socle automatisé solide ; scénarios de gameplay incomplets |
| 4 — constructeur ↔ bûcheron | `resource_delivery` est créé sur manque de bois et relie fournisseur/demandeur | Cycle générique et comptabilité exacte | Deux vraies entités mobiles convergent, aucun transfert n'a lieu à distance, la quantité exacte est remise à proximité et le rendez-vous reprend après redémarrage dans les deux profils | — | Livraison physique ciblée et recontrôle sans duplication validés ; déclenchement naturel au milieu d'un chantier complet non démontré |
| 4 — fermier ↔ cuisinier | La tâche persistante `food_support` est créée par le fermier et peut être complétée par une réponse alimentaire | Cycle de tâche dédié dans `collaborative_tasks_spec.lua` | Contrat isolé passé dans le runtime Lua de Luanti | — | Contrat validé ; cuisine, distribution et quantité physique non démontrées |
| 4 — mineur ↔ forgeron | La tâche persistante `mining_tool_supply` relie demande de pioche et réponse d'approvisionnement | Cycle de tâche dédié dans `collaborative_tasks_spec.lua` | Contrat isolé passé dans le runtime Lua de Luanti | — | Contrat validé ; forge et livraison réelle de l'outil non démontrées |
| 4 — danger ↔ gardes | `danger_response`, arrivée et complétion sont câblés | Cycle générique | — | — | Intervention/combat réel non démontré |
| 4 — disparition/changement de rôle/expiration | `participant_unavailable`, validation périodique et états `failed`/`expired` | Expiration et nettoyage testés dans `collaborative_tasks_spec.lua` | — | — | Entité réellement morte/déchargée non testée |
| 5 — interface village | Pages de dialogue, HUD, population, stocks, logements, danger, chantier, tâches et mode | Accès aux forms testé, pas le rendu | Chargement du formspec uniquement | — | Contenu statique riche ; lisibilité, chevauchements et expérience 30 minutes non observés |
| 5 — priorités | Équilibré, nourriture, défense, logement, production et exploration ; la sélection influe sur la spécialisation | Cas de priorité dans `needs_spec.lua` | — | — | Logique présente ; effet réel non mesuré |
| 5 — messages utiles | Anti-spam, intervalles et états bloqués sont présents dans plusieurs modules ; le coffre vide est pré-vérifié avec attente adaptative | `chest_cadence_spec.lua` prouve zéro trajet et zéro manipulation sur 221 décisions vides | Ressource apparue reprise sous le délai borné dans les deux profils | — | Spam de coffre ciblé corrigé ; volume et clarté globaux non évalués en jeu |
| 6 — contrôle propriétaire | `access.lua`, formulaires privés, inventaires et actions sont filtrés par propriétaire/admin ; village public explicite désactivé par défaut | `forms_access_spec.lua` et `access_spec.lua` | Owner/stranger/public contrôlés par le harnais | — | Bon socle automatisé ; aucun client multijoueur réel |
| 6 — allié/visiteur/admin | L'accès central implémente propriétaire, allié explicite, visiteur refusé, village public avec sceptre et administrateur | `access_spec.lua` couvre ajout/retrait d'allié, public et admin | — | — | Contrats synthétiques présents ; aucun scénario multijoueur réel |
| 6 — protections | Actions et chantiers appellent les vérifications de protection et la claim propriétaire | — | Deux vrais clients Luanti simultanés, deux villages/claims : creusage propriétaire autorisé et deux creusages croisés refusés par `minetest.node_dig` sous VoxeLibre | — | Claims chevauchants, coffre adverse, sceptre et réglage public encore à tester |
| 6 — survie serveur public | `survival.lua` applique PV, dégâts, armure/bouclier, protection d'activation, régénération, droits de frappe et seuil de fuite avant le mécanisme fatal du moteur | `survival_spec.lua` couvre réglages, migration, droits, dégâts, régénération et seuil | Coup réel 10→5, joueur étranger refusé et garde blessé en fuite sous les deux profils ; combat VoxeLibre 60 s contre zombies natifs, 4 victoires, 30 dégâts reçus, garde survivant | — | Combat natif prolongé prouvé sous VoxeLibre ; Minetest Game et bataille observée humainement restent ouverts |
| 6 — deux joueurs/deux villages | Isolation par propriétaire dans stockage, communication, population et tâches | Tests synthétiques d'isolation partielle | — | — | Scénario obligatoire non exécuté |
| 7 — couche de compatibilité | Mappings centralisés pour blocs, cultures, aliments, lits, portes, coffres, fours, établis, outils, armures et boucliers ; des fallbacks directs subsistent notamment dans garde, mineur et bûcheron | `compat_spec.lua` contrôle les candidats enregistrés et le catalogue du forgeron | Mappings et candidats réels, nourriture, four, logement, porte et spawn exercés dans les deux profils | — | Compatibilité de socle renforcée ; derniers fallbacks à centraliser et pas de validation métier par métier |
| 7 — VoxeLibre | Dépendances `mcl_*` optionnelles et profils dédiés | Assertions de compatibilité sous moteur | Cœur/suites positifs sur l'installation locale 0.92.1 corrigée ; spawn/reload, four, logement et porte positifs sur copie isolée ajustée | — | Pas une validation d'une copie VoxeLibre intacte ni d'un gameplay métier complet |
| 7 — `minetest_game` | Fallbacks `default:*`, `doors`, `beds`, `farming`, `flowers` et liste d'aliments vérifiés | Assertions de compatibilité et de non-aliment pour le blé | Cœur/reload, spawn/reload, four, logement et porte positifs au commit officiel indiqué | — | Socle headless validé ; aucun gameplay métier complet avec client |
| 8 — lint | `.github/workflows/luacheck.yml` installe Lua 5.1/LuaRocks/Luacheck et analyse les sources du dépôt hors sous-module tiers | — | — | — | Workflow écrit, jamais exécuté dans GitHub Actions pendant cet audit |
| 8 — tests Lua autonomes | Workflow dédié pour loader, besoins, population, accès/forms, collaboration, craft, horloge, coroutines, coffre, outils, fermier, plan de culture, terrain de chantier, autonome, livraison, mineur, sécurité artisanale et survie publique | Dix-neuf scripts intégrés | Dix-neuf suites exécutées dans des globals isolés du runtime Lua 5.1 de Luanti dans les deux jeux ; compatibilité, registre et recettes minerai séparés | — | Exécution locale moteur alpha.7 positive ; interpréteur externe, Luacheck et CI distante toujours non exécutés |
| 8 — tests stockage/migration | Spawn, population, collaboration, registre et ancienne staticdata ont des contrats ; logement persistant a du code de migration | Registre/collaboration/population couverts | Registre créé/rechargé, cinq identités conservées et staticdata sans inventaire migrée dans les deux jeux | — | Preuve moteur renforcée ; aucune migration d'une vraie sauvegarde utilisateur ancienne |
| 8 — spawn moteur réel | Harnais `working_villages_spawn_test` appelle le vrai chemin de production sur une plateforme headless jetable | — | Pour chaque jeu : cinq créations/cinq métiers, puis mêmes identités et zéro nouveau spawn au rechargement | — | Validé automatiquement pour un propriétaire et un scénario fixe uniquement |
| 8 — registre des chantiers et performance | Synchronisation persistante des marqueurs à la création, transition, destruction et chargement de mapblock | Registre et métriques dans le harnais principal | Un ancien marqueur est migré par un scan borné unique ; 250 requêtes de rayon 50 restent ensuite sur le chemin rapide sans scan cubique supplémentaire | — | Régression de performance ciblée positive ; charge avec plusieurs villages non mesurée |
| 8 — intégration village autonome | Harnais séparé à cinq PNJ, comptabilité globale et reprise en deux phases | Contrats de checkpoint et inventaires | Run v12 VoxeLibre neuf : cinq PNJ au moins 273 s, coffre, cinq outils, 31 arbres, semis/maturité, une récolte et échanges physiques | — | Minerai/dépôt, four, chantier et phase après redémarrage restent non confirmés dans v12 ; v17/v18 échouent diagnostiquement, v19 n'est pas exécuté et le verdict terminal reste absent dans les deux profils |
| 8 — tests manuels des deux jeux | Checklist existante dans le dépôt | — | — | Aucun | Bloquant pour toute déclaration « prêt à jouer » |

## Architecture et flux réel du code

Ordre de chargement principal :

```text
init.lua
  → loader.lua + log.lua
  → village_registry.lua
  → profil compatibilité + besoins/mémoire/décision/permissions
  → formulaires, logement, stockage, population, plans
  → API d'entité + craft + enregistrement des villageois
  → métiers spécialisés et autonome
  → spawn.lua
```

Flux de gameplay visé et producteurs observés :

```text
connexion joueur
  → spawn.lua / spawn_state.lua
  → population.lua et entité API
  → attribution initiale ou réaffectation par needs.lua
  → recherche du coffre propriétaire
  → récolte via jobs/* et async_actions.lua
  → dépôt au coffre
  → crafting.lua / four réel / forge ou cuisine
  → blueprint_construction.lua + builder.lua
  → building.lua (maison, lit, accès)
  → guard.lua + collaborative_tasks.lua
  → talking.lua / hud.lua pour l'état visible
```

Limite structurante actuelle : `village_registry.lua` définit une identité
persistante, un propriétaire, un centre/rayon et les collections de village.
Les intégrations statiques synchronisent déjà les habitants et zones de travail
depuis `population.lua`, le coffre principal/centre, les priorités, ressources et
danger depuis `api.lua`, les logements/lits et chantiers depuis `building.lua`,
ainsi que la gouvernance depuis `access.lua`. Les anciens stockages spécialisés
restent parallèles au registre. Celui-ci devient un index central, mais n'est
pas encore démontré
comme source de vérité unique après des sessions de gameplay et migrations
réelles.

## Modules actifs, historiques et incohérences

### Chargés et actifs

- `loader.lua`, `log.lua`, `compat/vl.lua`, `voxelibre_compat.lua` : démarrage
  et compatibilité.
- `api.lua`, `villager_state.lua`, `async_actions.lua`, `needs.lua`,
  `ai_decision.lua`, `memory.lua` : entité et décisions.
- `storage.lua`, `population.lua`, `village_registry.lua`, `building.lua`,
  `blueprints*.lua` : état et monde.
- `communication.lua`, `collaborative_tasks.lua`, `permissions.lua`,
  `access.lua` : collaboration et propriété.
- Les métiers chargés sont constructeur, suiveur, garde, collecteur, fermier,
  bûcheron, cuisinier, forgeron, mineur, marchand, autonome, apprenant,
  éclaireur à torches et déneigeur. Le marchand (27/09/2026) n'a encore
  aucune preuve de test autonome ni moteur ; voir JOBS.md.

### Historiques, morts ou faiblement reliés

- Le répertoire Git suivi `building_sign/` est supprimé dans le worktree. Le
  fichier `working_villagers/building_sign.lua` existe encore mais n'est pas
  chargé par `init.lua`; `building.lua` reste l'implémentation active.
- `working_villagers/deprecated.lua` est supprimé et n'est plus chargé.
- `jobs/EXAMPLE_enhanced_plant_collector.lua` est un exemple non chargé.
- `job_patterns.lua` est chargé et exposé, mais les recherches statiques ne
  trouvent son utilisation complète que dans le fichier d'exemple. Le charger
  en production apporte donc surtout du code dormant.
- `.luacheck_tidy` reste dans le dépôt après suppression du workflow dupliqué ;
  c'est une configuration historique non appelée par la nouvelle CI.
- `.gitmodules` et l'entrée Git `working_villagers/modutil` demeurent, alors que
  le code courant ne requiert plus ce sous-module. Les workflows locaux ne le
  récupèrent plus et l'excluent du lint du code propriétaire.
- `textures/working_villages_pixel.png` et
  `working_villagers/textures/working_villages_pixel.png` ont le même SHA-256.
  Seule la texture située dans le dossier du mod est nécessaire à l'exécution.

## Preuves réellement observées

### Tests Lua autonomes locaux

Les commandes externes `lua`, `lua5.1`, `luajit` et `luacheck` restent absentes
de l'environnement local. Toutefois, le harnais charge maintenant chaque suite
dans un environnement global isolé du runtime Lua 5.1 de Luanti. Les runs
source alpha.7 retenus du harnais principal contiennent exactement dix-neuf
marqueurs :

```text
STANDALONE_SPEC_OK:startup_spec.lua
STANDALONE_SPEC_OK:needs_spec.lua
STANDALONE_SPEC_OK:population_spec.lua
STANDALONE_SPEC_OK:access_spec.lua
STANDALONE_SPEC_OK:forms_access_spec.lua
STANDALONE_SPEC_OK:collaborative_tasks_spec.lua
STANDALONE_SPEC_OK:crafting_spec.lua
STANDALONE_SPEC_OK:timekeeping_spec.lua
STANDALONE_SPEC_OK:job_coroutines_spec.lua
STANDALONE_SPEC_OK:chest_cadence_spec.lua
STANDALONE_SPEC_OK:tool_fallback_spec.lua
STANDALONE_SPEC_OK:farmer_mature_priority_spec.lua
STANDALONE_SPEC_OK:crop_planner_spec.lua
STANDALONE_SPEC_OK:construction_planner_spec.lua
STANDALONE_SPEC_OK:miner_wood_bootstrap_spec.lua
STANDALONE_SPEC_OK:autonomous_bootstrap_wait_spec.lua
STANDALONE_SPEC_OK:resource_delivery_spec.lua
STANDALONE_SPEC_OK:blacksmith_builder_safety_spec.lua
STANDALONE_SPEC_OK:survival_spec.lua
```

Les journaux retenus sont
`test_harness/.runtime_public_integrated_vl_v4/audit_alpha7.log`
et
`test_harness/.runtime_public_integrated_mtg_v5/audit_alpha7.log`.
Chacun contient les dix-neuf marqueurs, `VILLAGE_REGISTRY_SPEC_OK`,
`ORE_SMELTING_RECIPES_OK:<profil>` et `WORKING_VILLAGES_TESTS_OK`.

Le test `village_registry_spec.lua`, la compatibilité et les recettes moteur de
minerai sont exécutés séparément dans le même harnais. Chaque profil produit la
version `0.13.0-alpha.7`, les dix-neuf marqueurs et
`WORKING_VILLAGES_TESTS_OK`, sans motif
`ERROR`, `FATAL`, `ModError`, `AsyncErr`, traceback, `attempt to yield` ou
`C-call boundary`. Cette preuve locale ne remplace pas l'exécution du workflow
GitHub Actions ni Luacheck. Aucune CI distante n'a été lancée ou observée.

Dans ce même passage moteur, `ORE_SMELTING_RECIPES_OK:<profil>` vérifie les
produits canoniques et les recettes de cuisson réellement enregistrées pour le
fer et l'or des deux jeux. `CONSTRUCTION_SITE_REGISTRY_MIGRATION_OK` confirme la
migration d'un ancien marqueur ; la mesure
`CONSTRUCTION_SITE_REGISTRY_FAST_PATH_OK` effectue ensuite 250 consultations de
rayon 50 sans second scan cubique. Ces contrôles restent distincts des dix-neuf
scripts autonomes et ne doivent pas être comptés comme des marqueurs
`STANDALONE_SPEC_OK` supplémentaires.

Le harnais physique de l'alpha.7 est retenu dans
`test_harness/.runtime_public_intelligence_vl_v21/runtime.log` et
`test_harness/.runtime_public_intelligence_mtg_v20/runtime.log`. Les deux
journaux contiennent `DETERMINISTIC_CROP_RUNTIME_OK`, `SAFE_SITE_SELECTED` et
`SAFE_CONSTRUCTION_RUNTIME_OK`, sans erreur critique. Ils prouvent le choix
stable de trois graines physiques, le refus d'un premier terrain invalide et
le dégagement réel d'une cellule intérieure. Ils ne prouvent pas la fin du
bâtiment ni sa consommation matérielle complète.

### Moteur réel, sans joueur

Les journaux moteur historiques alpha.4 retenus ont été produits sous Luanti
5.17.0 sous la racine :

```text
C:\Users\yanne\.codex\visualizations\2026\08\25\01a0394d-7b6c-7663-8056-a1ae088be88f
```

### Dernière alpha empaquetée et dernière installation observée

L'archive `0.13.0-alpha.7` du 27 septembre porte le SHA-256
`b429b80a0842b92b8bb01ca2cec1b4bb1cec1644c05c68bb5acd1e8828f355a7`.
Elle contient un unique dossier `working_villages/` et 114 fichiers couverts
par le manifeste. Son extraction donne zéro hash différent. Avec les
spécifications fournies séparément par `working_villages_specs`, ce paquet
extrait produit les dix-neuf suites puis `WORKING_VILLAGES_TESTS_OK` sous
VoxeLibre et Minetest Game, sans erreur critique.

Cette alpha.7 empaquetée n'a pas été copiée dans le dossier utilisateur ni sur
un serveur public pendant ce passage. La dernière installation réellement
observée reste l'archive `0.13.0-alpha.4` du 26 août, SHA-256
`8c623ff6201fb7af7f4079b27644c8f4eb34c87c955b8775c290f0d8dd8c6d20`,
installée dans
`C:\Users\yanne\AppData\Roaming\Minetest\mods\working_villages` avec 98
hashes conformes. Les preuves ci-dessous restent donc explicitement celles de
l'installation alpha.4 et ne doivent pas être réattribuées à l'alpha.7.

La copie alpha.4 réellement installée a été exécutée sous chaque profil avec un
harnais principal et un harnais moteur séparé :

- `installed_alpha4_vl_strict_20260826_1912/main/installed-alpha4-voxelibre-main.log`
  et `tool/installed-alpha4-voxelibre-tool-runtime.log` ;
- `installed_alpha4_mtg_strict_20260826_191225/installed_main_mtg_alpha4.log`
  et `installed_tool_runtime_mtg_alpha4.log`.

Les deux journaux principaux contiennent la version alpha.4, les dix marqueurs
de suites, `VILLAGER_LOGICAL_TIMERS_OK`, `C_CALLBACK_ASYNC_GUARDS_OK` et
`WORKING_VILLAGES_TESTS_OK`. Les deux journaux moteur contiennent
`EMERGENCY_RETREAT_RUNTIME_OK:<profil>` puis
`TOOL_FALLBACK_RUNTIME_OK:<profil>`. Les quatre ont zéro motif `ERROR`, `FATAL`,
`ModError`, `attempt to yield` ou `C-call boundary`.

Les harnais spécialisés finaux donnent :

- retraite d'urgence alpha.4 : vrai mineur, hostile de test et vrai callback
  `on_step` dans les deux profils ; chemin de fuite conservé entre plusieurs
  pas, sans pause ni changement de métier ;
- spawn VoxeLibre et Minetest Game : `WORKING_VILLAGES_INSTANCE_STATE_OK:5`
  puis `WORKING_VILLAGES_SPAWN_OK:created:5`; au second démarrage,
  `WORKING_VILLAGES_SPAWN_OK:reloaded:5`, sans erreur critique ;
- logement : `HOME_VALIDATION_SPEC_OK` dans les deux jeux, sans erreur
  critique ;
- four : `OFFLINE_FURNACE_CALLBACK_OK:voxelibre` et
  `OFFLINE_FURNACE_CALLBACK_OK:minetest_game`, deux sorties transférées avec
  compte exact et sans erreur critique ;
- portes : `DOOR_PLACEMENT_EXACT_OK:voxelibre` et
  `DOOR_PLACEMENT_EXACT_OK:minetest_game`, vraie recette, vrai `on_place`, paire
  bas/haut, orientation, consommation 2→1 et refus atomique si seul le haut est
  protégé ;
- mineur : pioche en bois fabriquée à coût exact, extraction après plus de dix
  nœuds de déplacement et dépôt du minerai dans les deux profils ;
- fermier : obtention d'une vraie graine naturelle, labour puis semis dans les
  deux profils ;
- livraison : un demandeur réellement mobile et son fournisseur convergent,
  aucun objet ne passe à distance, la tâche et le rendez-vous survivent au
  redémarrage, la quantité terminale est exacte et un démarrage ultérieur ne la
  duplique pas, dans les deux profils ;
- coffre vide : 221 décisions ne causent aucun trajet ni manipulation, au plus
  huit lectures légères sont effectuées et un objet candidat apparu est
  reprise sous le délai maximal de quatre secondes, dans les deux profils ;
- déplacement : `UNDERGROUND_CAVITY_RUNTIME_OK` puis
  `EMBEDDING_RECOVERY_RUNTIME_OK` dans les deux profils, avec même identité,
  inventaire, métier, état et coroutine après récupération. Une position sûre
  récente et revalidée permet la récupération dès le premier callback ; sans
  cache sûr, le fallback local attend trois callbacks.

### Scénarios de village complet v12 et v17 à v19

Le run `test_harness/.runtime_village_full_vl_source_v12` part d'un monde
VoxeLibre neuf. À 273 secondes, son journal conserve les cinq rôles et compte
31 arbres coupés, cinq outils, deux cultures semées dont au moins une mûre et
une récolte. Le coffre commun a été créé et de vrais dépôts/retraits y sont
journalisés. Cette progression ne suffit pas à déclarer la phase réussie : à ce
point, le compteur de minerai extrait est nul, aucun dépôt de minerai, four ou
marqueur de chantier n'est confirmé, et aucune phase de reprise après arrêt du
serveur n'a été exécutée. Le run v12 n'est donc pas un succès E2E.

Le journal
`test_harness/.runtime_village_full_vl_source_v17/phase1.log` se termine par
`WORKING_VILLAGES_VILLAGE_RUNTIME_FAILED` après l'expiration de la phase 1 : il
avait atteint le minerai et son dépôt, mais aucun verdict terminal n'a été
produit. Le journal v18 s'arrête pendant la phase 1 à 526 secondes sans marqueur
terminal ; ses relevés post-mortem ont servi au diagnostic de la pierre du four,
pas à valider la chaîne. V17 et v18 sont donc des échecs diagnostiques. Le
dossier v19 ne contient encore aucun journal de phase : ce scénario n'a pas été
exécuté.

Ces journaux ne sont pas sans avertissement. La distribution Luanti émet les
warnings de sommes SHA-256 et d'ancien backend de stockage ; chaque chargement
conserve aussi un `Calling this function during script init is disallowed` non
attribué. Sous VoxeLibre, un callback de documentation/XP exige un vrai
`PlayerRef` connecté : le mod préserve l'état correct de la porte ou du four,
conserve l'XP du four et déduplique l'avertissement hors ligne. Cette limite ne
doit pas être transformée en affirmation de compatibilité parfaite.

La copie VoxeLibre installée échouait initialement avant `working_villages`
avec `vl_hudbars/builtins.lua:157: attempt to index global 'mcl_gamemode' (a
nil value)`. L'ajout de `mcl_gamemode` aux dépendances de `vl_hudbars` a corrigé
l'ordre de chargement. Le harnais principal passe désormais sur cette
installation réelle, sans erreur ; celle-ci reste localement modifiée et ne
vaut donc pas preuve d'une distribution intacte.

### Test manuel

Pas de client lancé, pas de joueur connecté, aucune session graphique de 30 à
60 minutes, pas de déplacement de PNJ observé
par un humain, pas de cycle jour/nuit, pas de combat ni de fuite contre les mobs
natifs et pas de test visuel/sonore. Aucun métier n'a été validé manuellement
dans VoxeLibre ou `minetest_game`.

## Risques et blocages prioritaires

1. Exécuter une partie cliente de survie instrumentée dans **chaque** jeu :
   inventaire initial, groupe de
   cinq, coffre, agriculture, établi, four, cuisine, mine, forge, construction,
   lit et garde, avec bilan des stocks à chaque étape.
2. Tester deux joueurs et deux villages proches avec propriétaire, allié,
   visiteur, administrateur et un vrai mod de protection, y compris le réglage
   de propriétaire initial et le mode public explicite.
3. Exécuter physiquement les scénarios collaboratifs `food_support`,
   `mining_tool_supply` et `danger_response`. `resource_delivery` passe avec
   déplacement, quantité exacte et reprise ciblée, mais son déclenchement naturel
   au milieu d'un chantier complet reste à observer.
4. Tester les synchronisations du registre central avec la population, les
   zones de travail, coffres, logements, priorités, ressources, dangers et
   chantiers, puis éprouver les migrations sur une copie de **vrai ancien
   monde**, pas seulement sur des données synthétiques.
5. Définir explicitement l'expérience Minetest Game sans établi physique de
   base et confirmer au moins un aliment cru/cuit exploitable par le métier de
   cuisinier ; le four et les callbacks sont testés, pas ce design de gameplay.
6. Valider une distribution VoxeLibre intacte qui démarre seule. La copie
   locale installée démarre maintenant après correction de l'ordre
   `vl_hudbars`/`mcl_gamemode`, mais elle n'est donc plus intacte.
7. Finir la centralisation de compatibilité : coffres, fours, établis, outils,
   armures et boucliers passent désormais par les helpers communs dans l'API,
   le spawn, l'autonome, le cuisinier et le forgeron. Des listes directes
   `default:*`/`mcl_*` restent notamment dans garde, mineur et bûcheron ;
   l'exigence d'une couche unique n'est donc pas encore satisfaite.
8. Faire passer les deux nouveaux workflows CI. Leur simple présence ne prouve
   ni le lint vert ni les tests verts.
9. Mesurer les performances et la stabilité avec une population plafonnée sur
   une session longue, sauvegarde/rechargement et déchargement de zones.

## État Git exact du worktree (avant les commits du 27 septembre, voir plus bas)

Ce relevé inclut du travail antérieur appartenant à l'utilisateur et aux autres
itérations. Il ne signifie pas que les fichiers listés ont été créés ou
modifiés par un seul intervenant. Ceci est l'état constaté en début de
session, avant les commits décrits juste après ce bloc.

```text
 M .github/workflows/luacheck.yml
 D .github/workflows/tidy_luacheck.yml
 M .gitignore
 M API_REFERENCE.md
 M ARCHITECTURE.md
 M CONTRIBUTING.md
 M README.MD
 M ROADMAP.md
 M VALIDATION_CHECKLIST.md
 D building_sign/LICENSE
 D building_sign/README.MD
 D building_sign/areas.lua
 D building_sign/building.venus
 D building_sign/building_store.venus
 D building_sign/depends.txt
 D building_sign/forms.lua
 D building_sign/homes.lua
 D building_sign/init.lua
 D building_sign/locale/building_sign.de.tr
 D building_sign/locale/building_sign.en.tr
 D building_sign/locale/building_sign.template.tr
 D building_sign/mod.conf
 D building_sign/schematics.lua
 D building_sign/sign_meta.lua
 D building_sign/textures/default_sign_wall_wood.png
 D building_sign/textures/default_sign_wood.png
 M working_villagers/ai_behavior.lua
 M working_villagers/api.lua
 M working_villagers/async_actions.lua
 M working_villagers/blueprint_construction.lua
 M working_villagers/blueprint_forms.lua
 M working_villagers/blueprints.lua
 M working_villagers/blueprints_default.lua
 M working_villagers/building.lua
 M working_villagers/commanding_sceptre.lua
 M working_villagers/depends.txt
 D working_villagers/deprecated.lua
 M working_villagers/farming_compat.lua
 M working_villagers/forms.lua
 M working_villagers/groups.lua
 M working_villagers/guard_forms.lua
 M working_villagers/init.lua
 M working_villagers/job_coroutines.lua
 M working_villagers/jobs/autonomous.lua
 M working_villagers/jobs/blacksmith.lua
 M working_villagers/jobs/builder.lua
 M working_villagers/jobs/farmer.lua
 M working_villagers/jobs/guard.lua
 M working_villagers/jobs/learner.lua
 M working_villagers/jobs/miner.lua
 M working_villagers/jobs/plant_collector.lua
 M working_villagers/jobs/snowclearer.lua
 M working_villagers/jobs/torcher.lua
 M working_villagers/jobs/util.lua
 M working_villagers/jobs/woodcutter.lua
 M working_villagers/mod.conf
 M working_villagers/schems/fancy_hut.we
 M working_villagers/schems/simple_hut.we
 M working_villagers/settingtypes.txt
 M working_villagers/spawn.lua
 M working_villagers/talking.lua
 M working_villagers/util.lua
 M working_villagers/villager_state.lua
 M working_villagers/voxelibre_compat.lua
?? .github/workflows/standalone-tests.yml
?? AUDIT_STATUS.md
?? CHANGELOG.md
?? DEPLOYMENT.md
?? INSTALLATION.md
?? test_harness/README.md
?? test_harness/home_test.conf
?? test_harness/home_world.mt
?? test_harness/inventory_test.conf
?? test_harness/inventory_world.mt
?? test_harness/minetest.conf
?? test_harness/spawn_test.conf
?? test_harness/spawn_world.mt
?? test_harness/working_villages_door_test/init.lua
?? test_harness/working_villages_door_test/mod.conf
?? test_harness/working_villages_home_test/init.lua
?? test_harness/working_villages_home_test/mod.conf
?? test_harness/working_villages_inventory_test/init.lua
?? test_harness/working_villages_inventory_test/mod.conf
?? test_harness/working_villages_spawn_test/init.lua
?? test_harness/working_villages_spawn_test/mod.conf
?? test_harness/working_villages_test/init.lua
?? test_harness/working_villages_test/mod.conf
?? test_harness/world.mt
?? textures/working_villages_pixel.png
?? tools/deploy_local.ps1
?? tools/package_release.ps1
?? working_villagers/VERSION
?? working_villagers/access.lua
?? working_villagers/ai_decision.lua
?? working_villagers/blueprint_experiments.lua
?? working_villagers/collaborative_tasks.lua
?? working_villagers/communication.lua
?? working_villagers/compat/vl.lua
?? working_villagers/crafting.lua
?? working_villagers/hud.lua
?? working_villagers/inventory_access.lua
?? working_villagers/jobs/cook.lua
?? working_villagers/loader.lua
?? working_villagers/log.lua
?? working_villagers/memory.lua
?? working_villagers/needs.lua
?? working_villagers/permissions.lua
?? working_villagers/population.lua
?? working_villagers/schems/blacksmith_forge.we
?? working_villagers/schems/castle_fortress.we
?? working_villagers/schems/mine_entrance.we
?? working_villagers/schems/watchtower.we
?? working_villagers/schems/workshop.we
?? working_villagers/spawn_state.lua
?? working_villagers/tests/access_spec.lua
?? working_villagers/tests/collaborative_tasks_spec.lua
?? working_villagers/tests/compat_spec.lua
?? working_villagers/tests/crafting_spec.lua
?? working_villagers/tests/forms_access_spec.lua
?? working_villagers/tests/init.lua
?? working_villagers/tests/job_coroutines_spec.lua
?? working_villagers/tests/mod.conf
?? working_villagers/tests/needs_spec.lua
?? working_villagers/tests/population_spec.lua
?? working_villagers/tests/startup_spec.lua
?? working_villagers/tests/timekeeping_spec.lua
?? working_villagers/tests/village_registry_spec.lua
?? working_villagers/textures/working_villages_pixel.png
?? working_villagers/village_registry.lua
```

Le 27 septembre 2026, tout ce qui précède a été committé sur `master` en
trois commits distincts après `8eb12c2` :

1. documentation et audit (`README`, `ROADMAP`, `CHANGELOG.md`,
   `AUDIT_STATUS.md`, `INSTALLATION.md`, `DEPLOYMENT.md`, etc.) ;
2. harnais de test headless, spécifications autonomes et workflows CI
   (`.github/workflows/standalone-tests.yml`, `luacheck.yml`, `tools/`) ;
3. le code du mod lui-même (tous les nouveaux modules et métiers modifiés).

Une quatrième opération — la suppression de `building_sign/`,
`working_villagers/deprecated.lua` et
`.github/workflows/tidy_luacheck.yml` — reste **non committée**. L'agent qui
a produit ces trois commits n'avait pas l'autorisation d'exécuter un commit
supprimant des fichiers suivis (classé comme destruction locale
potentiellement irréversible par son environnement), même si un `git
revert` la défait sans perte de données. Le worktree contient donc encore
ces suppressions à l'état de modifications non indexées ; c'est à
l'utilisateur de committer ce nettoyage s'il le souhaite.

Aucun push vers `origin` n'a été effectué.

### Tentative de validation outillage (27 septembre 2026)

Une tentative d'installation d'un interpréteur Lua via Chocolatey a échoué
faute de droits administrateur sur cette machine. Aucun binaire Luanti ou
Minetest n'a été trouvé dans cet environnement (seuls des répertoires de
données d'exécutions passées, produites par un autre outil, existent sous
`~/.codex` et `~/AppData/Roaming/Minetest`). Le lint Luacheck et les tests
moteur réels restent donc impossibles à exécuter localement dans cet
environnement précis ; ceci ne change rien au statut décrit plus haut, qui
reposait déjà sur des exécutions antérieures faites ailleurs.
