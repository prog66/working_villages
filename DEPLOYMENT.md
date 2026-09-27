# Déploiement local de l'alpha

Version actuelle : `0.13.0-alpha.7`.

État documentaire mis à jour le 27 septembre 2026 (`2026-09-27`).

Cette version est une alpha locale. Elle a des preuves moteur ciblées, mais pas
encore de verdict terminal du harnais de village complet ni les validations
manuelles exigées pour une publication stable.

## Construire

Depuis la racine du dépôt :

```powershell
& .\tools\package_release.ps1
```

Le script copie une liste blanche depuis le worktree réellement testé. Il ne
fait volontairement pas `git archive HEAD`, car des fichiers runtime requis ne
sont pas encore suivis par Git. Il produit dans `dist/` :

- une archive avec un unique dossier racine `working_villages/` ;
- un manifeste SHA-256 par fichier dans le paquet ;
- un SHA-256 séparé de l'archive.

Les tests, mondes, journaux, fichiers Git, anciens sous-modules et sources
historiques non chargées sont exclus.

## Vérification source alpha.7 du 27 septembre 2026

La suite intégrée produit dix-neuf marqueurs `STANDALONE_SPEC_OK`, notamment
les nouvelles spécifications du plan de culture et du choix de terrain, puis
`WORKING_VILLAGES_TESTS_OK` sous VoxeLibre et Minetest Game. Les deux journaux
retenus ne contiennent ni `ERROR`, ni `FATAL`, ni `ModError`, ni `AsyncErr`, ni
traceback.

Un harnais moteur séparé a ensuite exercé de vraies entités et de vrais nœuds.
Dans chaque jeu, `DETERMINISTIC_CROP_RUNTIME_OK` confirme trois consommations
physiques d'une seule graine planifiée malgré deux types disponibles,
`SAFE_SITE_SELECTED` confirme le refus du premier terrain volontairement
invalide, et `SAFE_CONSTRUCTION_RUNTIME_OK` confirme que le constructeur a
réellement retiré une végétation placée dans le volume intérieur puis avancé
l'index et le registre comptable du chantier.

Cette vérification ne valide pas encore une construction complète avec tous
les matériaux, la boucle économique cinq métiers, un redémarrage au milieu du
chantier, une session graphique prolongée ou la charge d'un serveur public.

L'archive locale produite le même jour est
`dist/working_villages-0.13.0-alpha.7-local-20260927-s8eb12c28.zip`.
Son SHA-256 est
`b429b80a0842b92b8bb01ca2cec1b4bb1cec1644c05c68bb5acd1e8828f355a7` ;
114 fichiers sont couverts par le manifeste et le contrôle après extraction
donne zéro hash différent. L'archive extraite, sans ses tests internes et avec
les spécifications fournies par le mod de support externe, reproduit les
dix-neuf marqueurs puis `WORKING_VILLAGES_TESTS_OK` dans les deux jeux, sans
erreur critique. Cette réception valide le paquet local, pas une installation
ou un redémarrage de serveur public.

## Vérification source alpha.6 du 22 septembre 2026

La protection serveur public a été exercée avec une vraie entité et un vrai
`ObjectRef:punch` dans les deux jeux pris en charge. Les marqueurs
`PUBLIC_SERVER_SURVIVAL_RUNTIME_OK:<profil>` confirment 60 PV pour le villageois
masculin de base, un coup moteur brut de 10 réduit exactement à 5, la protection
d'activation et le refus d'un joueur étranger. Les marqueurs
`WOUNDED_GUARD_RETREAT_RUNTIME_OK:<profil>` confirment qu'un garde à 50 % de vie
fuit sans changer de métier ni de coroutine.

La suite intégrée complète produit désormais dix-sept marqueurs
`STANDALONE_SPEC_OK`, dont `survival_spec.lua`, puis
`WORKING_VILLAGES_TESTS_OK` sous VoxeLibre et Minetest Game. Aucun `ERROR`,
`FATAL`, `ModError` ou traceback n'est présent dans les journaux retenus.
Cette preuve est headless : elle ne remplace toujours pas une session publique
avec de vrais joueurs, des monstres du jeu et une charge prolongée.

## Vérification source alpha.5 du 27 août 2026

Avant empaquetage, la source alpha.5 a produit `WORKING_VILLAGES_TESTS_OK` sous
VoxeLibre et Minetest Game avec seize spécifications autonomes, plus les
contrôles séparés de compatibilité, de registre et des vraies recettes moteur de
minerai. Le catalogue chargé contient les douze plans par défaut réellement
enregistrés. Les régressions ciblées confirment aussi :

- le coffre vide sans trajet ni manipulation, avec attente adaptative et reprise
  d'un objet utile injecté dans le test sous quatre secondes ;
- l'amorçage en bois, l'extraction et le dépôt du mineur, ainsi que la graine
  naturelle, le labour et le semis du fermier dans les deux profils ;
- une livraison physique entre PNJ mobiles, sans transfert à distance, reprise
  après redémarrage et recontrôle sans duplication ;
- la récupération d'encastrement dès le premier callback avec cache sûr
  revalidé, ou après trois callbacks par recherche locale ;
- la migration bornée du registre de chantier, puis 250 consultations de rayon
  50 sans nouveau scan cubique.

Le run de village complet v12 ne constitue pas un feu vert de déploiement
stable. Dans un monde VoxeLibre neuf, il conserve cinq PNJ au moins 273 secondes
et atteint le coffre, cinq outils, 31 arbres, des cultures semées/mûres, une
récolte et des échanges physiques. Il ne confirme encore ni minerai/dépôt dans
ce scénario, ni four, ni chantier, ni reprise après redémarrage.

Les essais suivants ne changent pas ce verdict : v17 a expiré en phase 1 sans
validation terminale et v18 a été arrêté pour diagnostic sans marqueur de
succès. Ce sont deux échecs diagnostiques. Le monde v19 est préparé, mais son
scénario n'a pas encore été exécuté.

## Déployer dans le dossier utilisateur

```powershell
& .\tools\deploy_local.ps1 -PackagePath .\dist\<archive>.zip
```

La cible Windows par défaut est `%APPDATA%\Minetest\mods\working_villages`.
Le script vérifie les deux manifestes avant la copie. Il refuse d'écraser une
installation existante sans `-Replace`; dans ce cas, l'ancienne installation
est déplacée vers un dossier de sauvegarde horodaté avant la copie.

## Limite de publication

Ces scripts ne publient rien sur GitHub ou ContentDB. Une publication distante
nécessite encore une validation humaine explicite, les deux parcours manuels et
un choix de canal/version. Aucune session graphique de 30 à 60 minutes et
aucune CI distante n'ont encore été exécutées pour cette alpha.

## Dernier déploiement local observé : alpha.4 du 26 août 2026

L'archive figée
`dist/working_villages-0.13.0-alpha.4-local-20260826-s8eb12c28.zip` a été
installée dans
`C:\Users\yanne\AppData\Roaming\Minetest\mods\working_villages`.

- SHA-256 du ZIP :
  `8c623ff6201fb7af7f4079b27644c8f4eb34c87c955b8775c290f0d8dd8c6d20` ;
- 98 fichiers couverts par le manifeste, 99 avec le manifeste lui-même ;
- aucun fichier absent, supplémentaire ou de hash différent après copie ;
- chargement strict de cette installation réussi sous VoxeLibre et Minetest
  Game avec Luanti 5.17.0, dix suites isolées et
  `C_CALLBACK_ASYNC_GUARDS_OK`, sans `ERROR`, `FATAL` ni `ModError` ;
- harnais moteur réussi dans les deux profils avec
  `EMERGENCY_RETREAT_RUNTIME_OK:<profil>` et
  `TOOL_FALLBACK_RUNTIME_OK:<profil>`, sans `attempt to yield` ni
  `C-call boundary`.

Le VoxeLibre local 0.92.1 nécessitait séparément l'ajout de `mcl_gamemode` dans
les dépendances de `vl_hudbars`. Son fichier original a été sauvegardé avant la
correction. Le jeu réellement installé passe ensuite le harnais principal ; il
reste cependant localement modifié et ne remplace pas le test encore requis
sur une distribution VoxeLibre intacte.

Les spécifications utilisées pour ce contrôle restent dans un mod de support
externe au paquet. L'installation déployée n'a reçu aucun fichier de test et
reste conforme à son manifeste. Ces résultats sont des preuves serveur
headless ; le mod doit encore être activé dans un monde et parcouru avec un
client graphique.

Au 27 août 2026, aucune archive alpha.5 ni installation alpha.5 n'est encore
consignée dans ce document. Ne pas réutiliser le nom, le nombre de fichiers ou
le SHA-256 de l'alpha.4 pour présenter l'alpha.5 comme empaquetée ou déployée.
