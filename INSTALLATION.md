# Installation factuelle de `working_villages`

État vérifié le 27 septembre 2026. Ce document sépare volontairement la procédure
d'installation de la validation du gameplay. Une installation qui charge sans
erreur ne prouve pas que la boucle autonome complète fonctionne en partie.

## Prérequis

- Luanti avec le jeu choisi ; l'alpha.7 a été exercée sous Luanti 5.10.0 sous
  Windows, tandis que les harnais antérieurs ont aussi utilisé Luanti 5.17.0.
  Aucune version minimale plus ancienne n'a été validée.
- Un seul des jeux pris en charge par le code : `minetest_game` ou VoxeLibre.
- Une sauvegarde du monde avant d'ajouter le mod à une partie existante.

Le code courant utilise son propre chargeur `loader.lua`. Il n'a plus besoin du
mod externe `modutil` pour démarrer. Le dépôt conserve cependant encore une
entrée Git historique pour le sous-module `working_villagers/modutil`; elle
n'est pas une dépendance d'exécution du mod courant.

## Alpha locale empaquetée

Le canal local courant est `0.13.0-alpha.7`. Depuis la racine du dépôt,
`tools/package_release.ps1` fabrique une archive à liste blanche avec un seul
dossier `working_villages/`, un manifeste SHA-256 par fichier et un SHA-256 du
ZIP. `tools/deploy_local.ps1` vérifie ces deux niveaux avant installation et
sauvegarde toute version existante lors d'un remplacement explicite. La
procédure détaillée est dans [DEPLOYMENT.md](DEPLOYMENT.md).

Cette alpha reste soumise aux limites de l'audit : la réussite des contrôles
headless ne remplace ni une session graphique de 30 à 60 minutes dans chaque
jeu ni une CI distante. Aucune des deux n'a encore été exécutée.

## Copier le bon dossier

Le dossier source du mod est `working_villagers`, mais le nom déclaré dans
`mod.conf` est `working_villages`.

1. Copier uniquement le contenu de `working_villagers` dans le dossier des
   mods de Luanti.
2. Nommer le dossier de destination `working_villages` afin d'éviter toute
   ambiguïté.

Emplacements usuels :

- Windows : `%APPDATA%\Minetest\mods\working_villages\`
- Linux : `~/.minetest/mods/working_villages/`
- Installation limitée à un monde : `<monde>/worldmods/working_villages/`

Le fichier final doit donc être lisible à l'emplacement
`.../working_villages/mod.conf`, et non dans un niveau de dossier
supplémentaire.

## Partie neuve avec `minetest_game`

1. Installer `minetest_game` et créer un monde sans le mod.
2. Vérifier que ce monde démarre seul.
3. Installer le dossier `working_villages` comme indiqué ci-dessus.
4. Dans la configuration du monde, activer `working_villages`.
5. Laisser le mode `survival` par défaut, puis lancer le monde et examiner le
   journal Luanti.

Le profil attendu est détecté grâce au mod `default`. Les modules du jeu
utilisés par la couche de compatibilité comprennent notamment `default`,
`doors`, `beds`, `farming` et `flowers` lorsqu'ils sont disponibles.

**Limite de preuve :** le dépôt officiel `minetest_game` au commit
`c42e4d0c0ff9d27ff7b9b308c3cfc14098dd3a0f` a été cloné dans un dossier
temporaire. Le mod y a passé les harnais headless de chargement, four et spawn
persistant avec Luanti 5.17.0. Cette preuve moteur ne remplace ni l'installation
interactive de cette procédure ni un test en jeu avec un joueur.

## Partie neuve avec VoxeLibre

1. Installer VoxeLibre et créer un monde sans le mod.
2. Vérifier que le jeu de base démarre seul.
3. Installer le dossier `working_villages` comme indiqué ci-dessus.
4. Activer le mod dans la configuration du monde.
5. Laisser le mode `survival` par défaut, puis lancer le monde et examiner le
   journal Luanti.

Le profil attendu est détecté grâce à `mcl_core`. Les dépendances optionnelles
`mcl_*` sont déclarées dans `mod.conf` afin que Luanti ordonne leur chargement
lorsqu'elles sont fournies par le jeu.

### Défaut constaté dans la copie VoxeLibre installée

La copie locale VoxeLibre 0.92.1 examinée pendant l'audit ne démarrait pas telle
quelle, avant même le chargement de `working_villages`. Son fichier
`vl_hudbars/mod.conf` déclare seulement `mcl_util`, alors que
`vl_hudbars/builtins.lua` utilise `mcl_gamemode` pendant l'initialisation. Le
résultat observé est un `ModError` à la ligne 157, car `mcl_gamemode` vaut
encore `nil`.

Le 25 août 2026, la métadonnée de l'installation locale a été corrigée en
remplaçant `depends = mcl_util` par
`depends = mcl_util, mcl_gamemode`. L'original est conservé à côté sous le nom
`mod.conf.working_villages-backup-20260825-2104`, avec le SHA-256
`6e9852cb5d681756a10ec2be6fa2842b8dea84824a8fb46861c2e1451f535a94`.
Après cette correction, le jeu installé et `working_villages 0.13.0-alpha.1`
ont passé le harnais principal sous Luanti 5.17.0 sans `ERROR`, `FATAL` ni
`ModError`.

Cette correction concerne VoxeLibre, pas le mod. Une mise à jour du jeu peut
la remplacer. Elle ne constitue toujours pas une validation d'une distribution
VoxeLibre propre qui contiendrait déjà la bonne dépendance.

## Modes de jeu

Le réglage est lu dans `minetest.conf` :

```text
working_villages_gameplay_mode = survival
```

- `survival` est la valeur par défaut. Les matériaux illimités du constructeur,
  l'équipement gratuit du garde, la cuisson instantanée et les commandes
  d'expérimentation ne doivent pas être utilisés dans ce mode. Le sceptre doit
  être fabriqué à partir de la recette enregistrée.
- `creative_test` autorise explicitement les raccourcis de développement. Il
  ne doit pas servir à valider l'économie de survie.

Réglages prudents pour un premier monde :

```text
working_villages_gameplay_mode = survival
working_villages_enable_spawn = true
working_villages_enable_passive_spawn = false
working_villages_population_limit = 20
working_villages_population_radius = 64
working_villages_enable_population_growth = true
working_villages_auto_approve_autonomous_actions = true
working_villages_self_employed_public = false
working_villages_villager_hp_multiplier = 2.0
working_villages_incoming_damage_multiplier = 0.5
working_villages_player_damage_mode = owner_only
working_villages_activation_protection_seconds = 10
working_villages_health_regen_per_second = 0.25
working_villages_health_regen_delay_seconds = 20
working_villages_retreat_health_ratio = 0.5
working_villages_farmer_crop_strategy = uniform
working_villages_builder_step_interval = 0.5
working_villages_builder_site_min_radius = 6
working_villages_builder_site_max_radius = 30
working_villages_builder_site_attempts = 64
```

Le spawn passif reste désactivé ici pour éviter une multiplication ambiante par
ABM. La croissance autonome, lorsqu'elle est activée, est soumise au plafond,
à un logement libre et à un coût réel en nourriture selon le code courant.
Ce comportement n'a pas encore été validé dans une partie jouée. Sur un serveur
public où aucun joueur ne doit pouvoir blesser un PNJ, remplacer
`owner_only` par `none`. La valeur `all` rétablit les dégâts de tous les joueurs ;
les comptes ayant `protection_bypass` restent autorisés dans les trois modes.
Le constructeur prend ici une décision toutes les 0,5 seconde lorsqu'il a un
chantier ; augmenter cette valeur si plusieurs villages chargent le serveur.
Le budget de terrain est aussi plafonné automatiquement selon le volume du
plan, même si `builder_site_attempts` est réglé plus haut.

## Vérification minimale après installation

Une validation de chargement doit au minimum confirmer dans le journal :

- `[working_villages] loading init` ;
- le profil détecté (`VoxeLibre` ou `minetest_game`) ;
- `[working_villages] loaded init ...` ;
- aucune ligne `ModError`, `ERROR` ou `FATAL` imputable au mod.

Après un premier démarrage, fermer proprement le monde puis le relancer. Il
reste ensuite à vérifier manuellement, et non seulement dans le journal :

- absence de second groupe initial ;
- persistance des habitants, coffres, logements et chantiers ;
- consommation réelle des ressources ;
- travail de chaque métier ;
- respect des protections et de la propriété.

Les harnais dans `test_harness/` sont réservés à des mondes jetables :

- `working_villages_test` désactive le spawn et les dégâts, puis s'arrête sur
  le marqueur `WORKING_VILLAGES_TESTS_OK`. Il vérifie les contrats
  d'initialisation, de compatibilité, de stockage, de minuterie, de migration,
  d'abri, de portes et de livraisons exactes. Il exécute aussi dix-sept suites
  isolées : `startup`, `needs`, `population`, `access`, `forms_access`,
  `collaborative_tasks`, `crafting`, `timekeeping`, `job_coroutines`,
  `chest_cadence`, `tool_fallback`, `farmer_mature_priority`,
  `miner_wood_bootstrap`, `autonomous_bootstrap_wait`, `resource_delivery` et
  `blacksmith_builder_safety` et `survival` ; chacune
  doit écrire un marqueur `STANDALONE_SPEC_OK`. Le registre possède son marqueur
  séparé `VILLAGE_REGISTRY_SPEC_OK`.
- `working_villages_spawn_test` active le vrai chemin de spawn avec un
  propriétaire fixe. Le premier run doit produire
  `WORKING_VILLAGES_SPAWN_OK:created:5`; les suivants doivent produire
  `WORKING_VILLAGES_SPAWN_OK:reloaded:5` sans nouvelle identité. Le scénario a
  réussi en création puis rechargement sous les deux profils pendant cet audit.
- `working_villages_inventory_test` utilise le vrai nœud de four du jeu et
  exige deux retraits/callbacks exacts. Sous VoxeLibre, l'XP reste dans le four
  si le propriétaire est hors ligne ; sous Minetest Game, le callback standard
  accepte l'acteur hors ligne.
- `working_villages_home_test` vérifie avec le moteur la validation lit, porte,
  accès et unicité du logement.
- `working_villages_door_test` appelle le vrai `on_place` du craftitem porte du
  jeu, vérifie la paire bas/haut, l'orientation, la consommation exacte et le
  refus atomique si la moitié haute est protégée. Il a réussi dans les deux
  profils pendant cet audit.

Ces harnais ne simulent ni client humain, ni campagne complète de métiers, ni
économie autonome de bout en bout.

Le harnais de village complet ne possède toujours pas de verdict terminal :
v17 a expiré en phase 1, v18 a été arrêté pour diagnostic et v19 n'a pas encore
été exécuté. V17 et v18 sont des échecs diagnostiques, pas des validations.

Les runs retenus ne contenaient aucune ligne `ERROR`, `FATAL` ou `ModError`
imputable au mod. Les journaux comportent encore des avertissements du moteur
liés au harnais et à cette distribution Luanti ; un marqueur de réussite ne
signifie donc pas que le journal est sans warning. Toujours contrôler à la fois
le marqueur attendu et l'absence d'erreur.

## Statut de compatibilité à annoncer

- VoxeLibre : chargement du cœur et suites réussi sur l'installation locale
  0.92.1 après correction de sa dépendance ; four réel, logement, porte et
  spawn initial persistant également réussis sur la copie isolée ajustée avec
  Luanti 5.17.0 ; aucun test manuel complet des métiers.
- `minetest_game` : mêmes chargement/suites, callback de four réel, logement,
  porte et spawn persistant réussis sur le dépôt officiel au commit indiqué
  plus haut ; aucun test manuel complet des métiers.

En conséquence, le mod ne doit pas encore être présenté comme « prêt »,
« complet » ou « compatible à 100 % » avec les deux jeux.
