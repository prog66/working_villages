# Changelog

## 0.13.0-alpha.9 - 2026-09-27 (suite) - le mod ne chargeait plus du tout

### CRITIQUE : api.lua depassait la limite Lua de 200 variables locales

Decouvert le 28/09/2026 en deployant reellement ce depot sur un serveur
Luanti/VoxeLibre distant (la premiere fois cette session qu'un vrai
interpreteur Lua etait disponible) : le serveur refusait de demarrer,
en boucle de crash, avec
`ERROR[Main]: ...api.lua:6153: main function has more than 200 local
variables`. C'est une limite dure du langage Lua (`LUAI_MAXVARS = 200`,
identique en LuaJIT) sur le nombre de variables locales simultanement
actives dans une seule fonction ; le fichier entier `api.lua` est compile
comme une seule "fonction principale", donc chaque `local` et
`local function` declare au niveau superieur du fichier partage ce meme
budget de 200.

Ce bug est probablement latent depuis un moment : rien dans cette session
ni dans les sessions precedentes n'avait jamais eu acces a un vrai
interpreteur Lua ou moteur Luanti pour le detecter. Avec `api.lua` a 8018
lignes et des dizaines de fonctionnalites accumulees depuis alpha.1, le
fichier a fini par depasser la limite sans qu'aucun test autonome (qui
simule l'environnement Minetest mais ne recompile jamais le fichier via un
vrai interpreteur) ne puisse jamais l'attraper.

**Deroulement de l'incident** : le deploiement a ete tente avec confirmation
prealable de l'utilisateur, a echoue au demarrage, le serveur live a ete
restaure a la version precedente (alpha.6) en quelques minutes le temps du
diagnostic, sans perte de donnees de monde constatee (les checkpoints des
villageois ont ete restaures normalement au redemarrage).

**Correctif** : deux groupes de fonctions internes verifies par recherche
exhaustive (`grep`) comme n'etant references nulle part en dehors de leur
propre region du fichier ont ete enveloppes dans des blocs `do ... end` :
- le sous-systeme de "claims" de village (19 fonctions, lignes ~1694-2165) ;
- le sous-systeme de recuperation d'encastrement (12 fonctions + 5
  constantes, lignes ~6425-6706), avec `handle_embedded_body`
  pre-declaree a l'exterieur du bloc car c'est la seule fonction du groupe
  encore appelee bien plus loin dans le fichier (ligne ~7560).

Fermer un bloc `do...end` libere les emplacements de variables locales
qu'il contenait pour reutilisation par la suite du fichier, sans changer
la syntaxe d'aucun site d'appel existant.

**Verification, en l'absence d'interpreteur Lua local ou d'autorisation
d'en installer un sur le serveur distant** : un script Python autonome a
ete ecrit pour simuler precisement le calcul du compilateur Lua (suivi de
profondeur de bloc/fonction, variables de controle cachees des boucles
`for`, etc.), puis calibre sur le fichier original en confirmant qu'il
detecte bien un pic de **201** variables **exactement a la ligne 6153** —
correspondant exactement au message d'erreur reel du serveur. Sur le
fichier corrige, ce meme script mesure un pic de **182**, soit une marge
de 18 sous la limite. Ce script reste une simulation statique, pas une
execution reelle du fichier corrige ; ce niveau de preuve exact est note
ici honnetement plutot que presente comme une correction testee de bout
en bout. Une nouvelle tentative de deploiement sur le meme serveur reste
necessaire pour obtenir une vraie preuve moteur de ce correctif.

### API_REFERENCE.md complete pour les nouveaux modules

Meme lacune que pour ARCHITECTURE.md : aucune fonction de `needs.lua`,
`inventory_access.lua`, `crafting.lua`, `communication.lua`,
`collaborative_tasks.lua` ou `access.lua` n'etait documentee. Ajout d'une
section ciblee sur les fonctions les plus utiles a un auteur de nouveau
metier, avec verification de chaque signature/comportement dans le code
source avant redaction plutot que par supposition. Deux erreurs ont ete
trouvees et corrigees pendant cette verification, avant tout commit :
- `needs.get_low` a ete d'abord documentee a tort comme triee par
  priorite avec un champ `executable` ; elle retourne en realite une
  liste non triee de `{name, level, value}`.
- `crafting.ensure_item`'s `opts.max_depth` a ete d'abord documente comme
  un reglage effectif, avant de verifier que `ensure_any_item` (le point
  d'entree utilise par `blacksmith.lua`) ne transmet jamais ce reglage a
  `ensure_item` : l'option est en realite un no-op silencieux la ou elle
  est utilisee aujourd'hui. Note ajoutee directement dans la
  documentation plutot que laissee de cote.

### ARCHITECTURE.md remis a niveau

Ce document decrivait encore l'etat du mod d'avant l'alpha.1 : aucun des
modules ajoutes depuis (needs, memoire, decision, permissions, access,
village_registry, population, communication, collaborative_tasks,
survival, hud, crafting, economy_recipes, construction_planner,
crop_planner, blueprint_experiments, compat/vl, loader, log, timers,
work_fallback, inventory_access) n'y etait mentionne, la liste des
metiers en oubliait quatre (cook, autonomous, learner, trader), et il
affirmait a tort que `modutil` restait une dependance obligatoire. Mis a
jour pour refleter l'etat reel du code, avec renvoi vers AUDIT_STATUS.md
pour le niveau de preuve de chaque partie plutot que de dupliquer cette
information ici.

### Page de garde a affichage double corrigee

`working_villages:guard_check` (une page de secours qui redirige vers la
config garde ou explique que ce villageois n'est pas garde) appelait
`forms.show_formspec` sur `guard_config` depuis son propre constructeur
puis retournait une chaine vide : le client recevait donc un vrai
formulaire de configuration garde, immediatement suivi d'un deuxieme
formulaire vide sous un autre nom, effacant le premier. Cette page n'est
plus reliee depuis le menu normal (le lien direct pointe deja vers
`guard_config`), donc non observable en jeu actuellement, mais corrigee
par prudence : `guard_config_constructor` a ete extrait en fonction
nommee, que `guard_check` appelle desormais directement pour recuperer le
vrai contenu du formulaire au lieu de declencher un second affichage.

### Menu perime = impasse silencieuse

Quand `forms.show_formspec` recevait un nom de formulaire non enregistre,
elle affichait bien le menu de discussion en secours, mais sous le nom
d'origine (non enregistre) au lieu du vrai nom du menu. Tous les boutons de
ce formulaire de secours devenaient alors une impasse silencieuse : le
gestionnaire de reception de champs cherche une correspondance exacte par
prefixe dans les pages enregistrees, ne la trouve jamais pour un nom
bidon, et n'appelle donc jamais aucun `receiver`. Corrige en renommant
`formname` vers `"working_villages:talking_menu"` en meme temps que la
page de secours est choisie. Piste pre-existante, pas introduite par cette
session ; aucun appelant actuel connu ne declenche ce chemin, mais le
correctif est sans risque et rend le code defensif reellement correct.

### Deduplication de helpers de construction

`parse_schematic_content` (parseur de fichier .we) etait definie a
l'identique dans `building.lua` et `blueprints.lua` ; `get_bounds` (calcul
de boite englobante) etait definie deux fois avec la meme logique dans
`construction_planner.lua` et `blueprint_construction.lua`, avec une
difference mineure (l'une retournait de vrais vecteurs via `vector.new`,
l'autre de simples tables `{x,y,z}`). Dans les deux cas, seule la copie la
plus ancienne (celle chargee en premier par `init.lua`) est conservee ; les
fichiers charges apres la reutilisent au lieu d'en garder une copie a
maintenir manuellement en double. Verifie que le seul site d'appel de
`get_bounds` dans `blueprint_construction.lua` n'utilise que
`vector.add`/`vector.subtract`/`minetest.find_nodes_in_area`, qui
acceptent une simple table `{x,y,z}` sans avoir besoin de la metatable
vecteur.

### Forgeron bloque par un four encombre

Si un objet non-minerai se trouvait dans l'emplacement source d'un four
(depose par un joueur, ou laisse par un autre metier), le forgeron
retentait indefiniment ce meme four : `use_furnace_inventory` refusait de
l'utiliser mais `find_nearby_furnace` continuait a le proposer comme "four
existant" a chaque tick, sans jamais chercher d'alternative ni envisager
d'en construire un autre. Corrige en reutilisant le mecanisme deja existant
`working_villages.failed_pos_record`/`failed_pos_test` (le meme qui evite
deja de retenter un site de chantier invalide) : un four juge inutilisable
est ignore pendant quelques minutes par `find_nearby_furnace`, utilise par
le forgeron, le cuisinier, le mineur et l'autonome. Note : `cook.lua` a une
forme de code differente pour le meme scenario (il ne bloque pas de la
meme facon) et n'a pas ete touche ici ; a revisiter separement si besoin.

### Nouveau metier : marchand

`working_villages:job_trader` mane un poste de troc. Contrairement aux
autres metiers, il ne recolte, ne construit ni ne combat rien ; sa seule
fonction est un lien "Poste de troc" dans son menu de discussion qui ouvre
une fenetre a distance sur le vrai coffre commun du village, via les
widgets natifs `list[]`/`listring[]` de Minetest — le moteur gere lui-meme
le transfert d'objets, exactement comme pour n'importe quel coffre ouvert
directement. Ce choix de conception est deliberement conservateur :
puisqu'aucun interpreteur Lua ni moteur Luanti n'etait disponible pour
tester ce code, la logique de transfert repose entierement sur le widget
de coffre deja eprouve du moteur plutot que sur du nouveau code de
manipulation d'inventaire ecrit ici.

Points d'attention traites pendant l'implementation :
- La page `working_villages:trader_post` a ete gardee par
  `requires_manage = true` avant tout commit — sans ce garde-fou, n'importe
  quel joueur aurait pu vider le coffre commun d'un village qui n'est pas
  le sien en parlant a un seul de ses villageois, exactement la classe de
  faille corrigee plus haut pour le tableau du village.
- La mise en page du formulaire utilise une grille de coffre fixe (8x4)
  et des positions absolues plutot qu'une hauteur calculee dynamiquement
  a partir de la taille reelle du coffre (27 emplacements sous VoxeLibre
  contre 32 sous minetest_game) : un premier calcul dynamique aurait
  depasse la hauteur du formulaire dans le pire cas.
- Voir [JOBS.md](JOBS.md) pour le detail complet et le niveau de preuve
  (code uniquement, aucun test moteur).

### Suite de la revue de code

Poursuite de la revue automatisee sur la file d'attente de
pistes laissees par alpha.8.

### Corrections

- **Armure retiree sans raison** : `equip_best_armor` comparait la piece
  deja equipee en ne regardant que le groupe `armor_points`, alors que le
  score des candidats regardait aussi le groupe `armor` en repli. Une piece
  deja equipee qui n'utilise que le groupe `armor` (score reel > 0) etait
  donc lue a tort comme un score de 0, et remplacee par n'importe quel
  candidat, meme equivalent ou pire. Les deux comparaisons utilisent
  maintenant le meme calcul de score (`item_armor_points`, aussi
  reutilise par `get_armor_points`, qui faisait deja le bon calcul).
- **Index de chantier compte double** : quand un constructeur finissait de
  degager une serie de cellules d'air en fin de plan (le tableau de noeuds
  s'epuisait exactement a la fin de la boucle), l'index de progression du
  marqueur de chantier recevait un `+1` supplementaire en plus de celui
  deja applique dans la boucle. Sans consequence visible aujourd'hui (le
  test de fin de chantier utilise `> node_count`), mais aurait fausse toute
  future logique basee sur l'index exact (pourcentage de progression,
  comptabilite). Corrige dans `jobs/builder.lua`.
- **Double definition de `is_furnace`** : `voxelibre_compat.lua` et
  `compat/vl.lua` definissaient chacun `is_furnace` sur la meme table
  partagee (`compat/vl.lua` charge `voxelibre_compat` et redefinit dessus).
  La version de `compat/vl.lua` gagnait toujours silencieusement ; celle de
  `voxelibre_compat.lua` était non seulement morte mais aussi moins
  correcte (comparaison stricte `== "default:furnace"`, qui rate
  `default:furnace_active`, l'etat allume du four dans minetest_game).
  Version morte retiree, un seul point de verite desormais.

## 0.13.0-alpha.8 - 2026-09-27

Alpha de revue de code et de lisibilité HUD, lancée en continu (boucle de
travail) suite à un audit complet du dépôt. Cette entrée sera complétée au
fil des itérations suivantes de la même revue.

### Corrections de securite/vie privee

- **Fuite de position corrigee** : la page "Tableau du village" (accessible
  en clic-droit sur N'IMPORTE QUEL villageois, y compris ceux d'un village
  qui n'est pas le vôtre) affichait les coordonnées exactes du coffre
  commun, du poste de travail et de la maison du villageois sélectionné,
  sans aucune vérification de propriétaire. N'importe quel joueur pouvait
  donc repérer précisément où piller un village adverse. Les coordonnées ne
  sont désormais montrées qu'aux joueurs ayant les droits de gestion sur ce
  village (propriétaire ou allié avec droits) ; le reste du tableau
  (population, métiers, ressources agrégées) reste visible en lecture seule
  comme prévu par le design existant. Trouvé et corrigé le 27 septembre 2026
  suite à une revue de code automatisée sur l'ensemble du diff depuis
  `8eb12c2`.

### Corrections

- **HUD persistant enfin visible** : les barres de besoins (faim, énergie,
  outils, matériaux) et l'icône de statut du HUD étaient construites en
  colorisant `blank.png`, la texture transparente conventionnelle des deux
  jeux supportés — coloriser une texture transparente reste transparent.
  Le HUD affichait donc uniquement du texte, sans aucune barre visible,
  depuis son introduction. Le HUD utilise maintenant la texture opaque du
  mod (`working_villages_pixel.png`, déjà présente dans le dépôt mais
  jamais utilisée) et ajoute : un fond semi-transparent derrière le bloc
  pour la lisibilité, une couleur dédiée par barre de besoin, le nom et le
  métier du villageois suivi, et un résumé du village (population par
  métier) quand aucun villageois du joueur n'est à proximité.
- Le combat de secours (`villager:atack`) forçait au moins 1 point de
  dégâts via `set_hp` quand `punch()` laissait les PV inchangés ; ce
  mécanisme de repli (nécessaire pour certains mobs VoxeLibre dont
  `punch()` seul ne suffit pas) ne vérifie plus jamais une cible joueur
  avant de forcer ses PV. Aucun appelant actuel ne visait un joueur
  (`is_enemy()` les exclut déjà), donc ce changement est une protection
  défensive plutôt qu'une correction de comportement observé.
- Le niveau de notification "detaillees" perdait silencieusement tous les
  messages d'état d'un villageois quand son propriétaire était hors ligne,
  au lieu de les rediriger vers le joueur connecté le plus proche comme les
  autres niveaux ; il vérifie maintenant que le propriétaire est bien
  connecté avant d'utiliser ce chemin dédié.
- Correction d'un test (`village_registry_spec.lua`) qui passait un
  booléen comme message d'erreur au lieu d'un texte descriptif.
- CI : `ore_smelting_spec.lua` (comme `compat_spec.lua`) nécessite un vrai
  moteur Luanti et n'était pas documenté comme exclu du job Lua autonome ;
  le résumé du workflow le mentionne maintenant explicitement.
- Nettoyage de code mort/pièges trouvés par la revue : variable locale
  `voxelibre_compat` jamais utilisée dans `util.lua` ; `compat/vl.lua`
  masquait la fonction globale `pairs` avec une variable locale du même nom
  dans `build_bed_pairs` (aucun bug actuel, mais un piège pour un futur
  ajout de boucle dans cette fonction).
- Vérifié : le changement de clé de maturité des cultures VoxeLibre dans
  `farming_compat.lua` (`mcl_farming:wheat_8` -> `mcl_farming:wheat` sans
  suffixe) signalé comme suspect par la revue est intentionnel et déjà
  documenté en commentaire dans le fichier ; dans `mcl_farming`, les stades
  de croissance sont numérotés mais la culture mûre finale prend le nom
  sans suffixe. Aucune action nécessaire.
- **Villageois "bloque" apres reprise reste corrige** : quand le metier d'un
  villageois echouait 3 fois de suite, il etait mis en pause avec la raison
  "error" et le joueur (ou le minuteur automatique de reprise a 200 ticks)
  pouvait lever cette pause, mais le compteur d'echecs interne
  (`job_data.job_error_state.exhausted`) n'etait jamais efface : le
  villageois semblait actif (non pause, anime normalement) mais son metier
  ne s'executait plus jamais, sans aucun message d'erreur repete pour
  l'expliquer. La seule echappatoire etait de changer son metier puis de le
  remettre. `villager_state.lua:set_pause(false)` efface maintenant l'etat
  d'erreur du metier quand la pause levee avait pour raison "error".
- Nouveau test `tests/villager_state_spec.lua` couvrant `set_pause` (y
  compris la correction ci-dessus) et le repli "detaillees" -> joueur le
  plus proche de `set_state_info` corrige plus haut ; ajoute au workflow
  CI `standalone-tests.yml`.

### Revue en cours

Une revue de code automatisée à 10 agents a été lancée sur l'intégralité du
diff depuis `8eb12c2` (documentation, harnais de test, code du mod). Au-delà
des corrections ci-dessus, elle a remonté une dizaine d'autres pistes
(plausibles, non toutes confirmées) qui seront traitées dans les prochaines
itérations : score d'armure incohérent entre pièce équipée et candidate
dans `equip_best_armor`, réinitialisation du dépassement d'échecs d'un job
non nettoyée par une reprise manuelle au sceptre, `on_start` d'un job
ré-exécuté à chaque tick faute de yield dans la plupart des `jobfunc`,
scans de protection redondants dans `inventory_access.lua`, et duplication
de `parse_schematic_content`/`get_bounds` entre `building.lua`,
`blueprints.lua` et `construction_planner.lua`. Voir l'historique de session
pour le detail complet par fichier.

## 0.13.0-alpha.7 - 2026-09-27

Alpha de cohérence agricole et de construction pour serveur public.

### Corrections

- plan de culture persistant et indépendant de l'ordre des piles ramassées,
  avec modes `uniform`, `rows` et compatibilité `available` ;
- replantation d'une récolte uniquement avec sa graine correspondante et
  replanification différée lorsqu'une graine prévue manque réellement ;
- recherche déterministe des terrains de chantier, validation de toute
  l'emprise, du sol, des liquides, des protections, des obstacles et d'un
  accès périphérique ;
- ajout des cellules d'air manquantes aux plans afin de dégager l'intérieur
  avant de fermer un bâtiment, avec refus d'emmurer un obstacle solide ;
- réservation immédiate du chantier par le constructeur qui l'ouvre, au lieu
  de repartir en soutien logistique avant de le redécouvrir ;
- déplacement vers les cellules à dégager, utilisation de la main du jeu pour
  les éléments creusables sans outil et suppression immédiate de la petite
  végétation de chantier ;
- suppression des recherches de chemin inutiles lorsque le PNJ est déjà à son
  poste ou à portée de sa culture ;
- budget de validation proportionnel à la taille du plan pour éviter les pics
  de scan lors de la recherche d'un terrain pour une grande structure ;
- besoins matériels réels restaurés pour les plans générés `garden` et
  `farm_plot`.

### Preuves observées

- dix-neuf spécifications intégrées, puis `WORKING_VILLAGES_TESTS_OK`, sous
  Minetest Game et VoxeLibre, sans erreur critique dans les journaux retenus ;
- dans les deux jeux, un vrai fermier a consommé trois graines physiques d'un
  seul type alors que deux types étaient présents dans son inventaire ;
- dans les deux jeux, le premier terrain volontairement humide ou occupé a été
  refusé, un autre terrain sûr a été sélectionné et un vrai constructeur a
  retiré la végétation d'une cellule intérieure avant d'avancer le chantier ;
- ces preuves restent headless et ciblées : le parcours économique complet,
  une session graphique prolongée, la charge multijoueur et la CI distante ne
  sont toujours pas validés.

## 0.13.0-alpha.6 - 2026-09-22

Alpha de préparation serveur public centrée sur la survie des PNJ.

### Corrections

- calcul des dégâts pris en charge avant le mécanisme fatal de Luanti, au lieu
  de rendre des PV après un coup qui pouvait déjà avoir supprimé l'entité ;
- PV maximaux doublés et dégâts entrants divisés par deux par défaut, après
  réduction d'armure et de bouclier ;
- protection de dix secondes après apparition ou rechargement de mapblock ;
- régénération lente après vingt secondes sans danger, uniquement si le PNJ
  n'est pas affamé ;
- dégâts directs des joueurs limités au propriétaire par défaut, avec modes
  `none` et `all`, et maintien du privilège administratif
  `protection_bypass` ;
- fuite déclenchée dès le premier coup accepté ; à 50 % de vie, les gardes
  rompent aussi le combat sans perdre leur métier ni leur coroutine ;
- migration unique des anciennes sauvegardes vers les nouveaux PV en
  conservant le pourcentage de santé, sans soin gratuit aux rechargements
  suivants.

### Preuves observées

- coup réel moteur 10→5, protection d'activation et joueur étranger refusé
  sous VoxeLibre et Minetest Game ;
- garde blessé réellement orienté vers la fuite dans les deux profils ;
- dix-sept spécifications intégrées puis `WORKING_VILLAGES_TESTS_OK` dans les
  deux jeux, sans erreur critique dans les journaux retenus ;
- aucune bataille graphique prolongée, charge multijoueur publique ni
  campagne de monstres natifs encore exécutée.

## 0.13.0-alpha.5 - 2026-08-27

Alpha locale de consolidation P0. Elle renforce les comportements de survie et
les preuves moteur ciblées, mais ne valide encore ni l'économie autonome
complète du village ni le plaisir de jeu.

### Corrections

- sélection et fabrication d'une pioche réellement capable selon
  `minetest.get_dig_params`, avec prise en charge des groupes VoxeLibre ;
- amorçage du mineur par l'outil en bois avant les recettes pierre/fer qui ne
  sont pas encore approvisionnées ;
- classification centralisée des minerais et dépôt réel de leur produit ;
- vérification, auprès du moteur de chaque jeu, des minerais métalliques, de
  leurs produits canoniques et de leurs vraies recettes de cuisson ;
- creusage hors ligne compatible avec les callbacks VoxeLibre, sans céder à
  travers la frontière C ;
- replantation du bûcheron rattachée à la bonne entité ;
- amorçage du fermier à partir d'une graine naturelle, puis labour et semis
  réels sans injection de culture ;
- conservation exacte des sorties du forgeron lors d'un dépôt partiel ou
  refusé ;
- recettes agricoles réelles pour la botte de paille, le lit et le pain plat ;
- pré-vérification des coffres et attente adaptative : un coffre sans objet
  utile ne provoque plus de trajet ni de message à chaque décision ;
- rendez-vous de livraison physique poursuivi lorsque le demandeur se déplace,
  sans transfert à distance, puis reprise exacte après redémarrage sans perte
  ni duplication ;
- récupération d'un PNJ encastré dès le premier callback lorsqu'un cache récent
  de position sûre peut être revalidé ; sans cache sûr, le repli local reste
  borné à trois callbacks. L'identité, l'inventaire, le métier, la tâche et la
  coroutine sont conservés, et une cavité minière praticable n'est pas traitée
  comme un encastrement ;
- index persistant des chantiers : une migration ancienne effectue un unique
  scan borné, puis les consultations passent par le registre sans répéter le
  scan cubique ;
- catalogue documentaire aligné sur les douze plans réellement enregistrés.

### Preuves observées

- seize spécifications isolées, plus compatibilité, registre et recettes
  moteur de minerai, réussies sous
  VoxeLibre et Minetest Game avec la version `0.13.0-alpha.5` ;
- `ORE_SMELTING_RECIPES_OK:<profil>` confirme les vraies recettes moteur de
  minerai dans les deux profils ;
- livraison physique exacte entre deux vrais PNJ mobiles avec reprise après
  redémarrage, proximité obligatoire et recontrôle ultérieur sans duplication ;
- cycles ciblés bûcheron, fermier jusqu'au semis et mineur jusqu'au dépôt ;
- contrat moteur de sécurité forgeron/constructeur contre les pertes et
  duplications partielles ;
- récupération d'encastrement et maintien d'une cavité minière légitime testés
  avec de vraies entités dans les deux profils ;
- registre de chantier migré avec un scan borné, puis 250 consultations de
  rayon 50 restées sur le chemin rapide du registre ;
- scénario strict v12 dans un monde VoxeLibre neuf : cinq PNJ encore présents
  à 273 s, coffre commun, cinq outils, 31 arbres coupés, cultures semées et
  mûres, une récolte et des échanges physiques observés ; minerai/dépôt, four,
  chantier et reprise après redémarrage n'y sont pas encore confirmés ;
- les essais v17 et v18 du village complet sont des échecs diagnostiques sans
  verdict terminal ; v19 est préparé mais n'a pas encore été exécuté ;
- aucune session graphique de 30 à 60 minutes, aucun cycle complet de chaque
  métier, aucune économie complète des cinq PNJ, aucun multijoueur, aucune
  migration d'une vraie sauvegarde, aucune CI distante ni exécution de
  Luacheck.

## 0.13.0-alpha.4 - 2026-08-26

Correctif local des actions asynchrones déclenchées depuis les callbacks du
moteur. La retraite d'urgence n'appelle plus une coroutine avec `yield`
directement depuis `luaentity_Step` : elle conserve désormais une cible de
fuite et un chemin indépendants, avancés d'un pas par callback sans écraser la
navigation suspendue du métier.

La pose d'entretien appelée depuis `on_step` conserve ses contrôles de
protection et sa comptabilité d'inventaire, mais n'essaie plus de céder la main
à travers la frontière C. La durée d'alerte est également normalisée par le
temps moteur au lieu de dépendre du nombre d'images serveur.

Le harnais moteur ajoute un hostile réel autour d'un vrai mineur et exerce le
chemin complet `on_step -> danger -> fuite` plusieurs fois. Le harnais principal
contrôle aussi `go_to` et la pose directe depuis un contexte non yieldable.

## 0.13.0-alpha.3 - 2026-08-25

Correctif local complémentaire après le test d'une vraie entité : les groupes
de creusage `pickaxe` sont désormais traduits vers les noms d'items `pick_*`
des deux jeux. Le constructeur peut donc rechercher et fabriquer les vrais
candidats de pioche au lieu de passer directement à la demande externe.

Le nouveau harnais moteur crée un vrai mineur sans pioche, vérifie qu'il reste
actif et dans son métier sans créer de ressource, lui livre exactement une
pioche du jeu, puis vérifie son équipement et la reprise. Il reste headless et
ne remplace pas un playtest graphique.

## 0.13.0-alpha.2 - 2026-08-25

Alpha locale de réactivité et de débrouille. Elle reste une version de
développement, sans validation manuelle du plaisir de jeu ni de l'économie
autonome complète.

### Corrections

- rétablissement du rythme historique des décisions avec des timers normalisés
  par le temps moteur et indépendants du FPS serveur ;
- équipement automatique d'une pioche, hache ou pelle déjà portée, récupérée
  dans le stockage partagé ou fabriquée avec les ressources réelles ;
- demande d'outil immédiate et identifiée, avec cooldown résistant au
  redémarrage et commandes de forgeron dédupliquées ;
- mineur, bûcheron et constructeur conservent leur métier et ramassent des
  fournitures réelles ou inspectent leur zone pendant l'attente ;
- le constructeur ne se met plus en pause globale lorsqu'un outil manque ;
- fermier, garde et autonome évitent les premiers délais artificiels ;
- l'autonome ne tente plus d'abattre ni de condamner un arbre sans hache.

### Validation observée avant empaquetage

- suite source sous Luanti 5.17.0 avec VoxeLibre 0.92.1 local et Minetest Game ;
- dix spécifications isolées dans chaque profil, dont la nouvelle régression
  `tool_fallback_spec.lua` ;
- aucune preuve de partie graphique, de cycle complet minerai → outil →
  livraison, ni d'autonomie hors zone chargée.

## 0.13.0-alpha.1 - 2026-08-25

Première alpha locale traçable issue de l'audit d'autonomie. Ce paquet n'est
pas une publication ContentDB et ne doit pas être présenté comme stable.

### Ajouts et corrections majeurs

- chargeur local sans dépendance d'exécution à `modutil` ;
- modes `survival` et `creative_test` séparés ;
- spawn initial persistant de cinq rôles, plafond de population et priorité de
  propriétaire corrigée ;
- registre persistant de village, besoins, logements, permissions et tâches
  collaboratives ;
- consommation et callbacks réels pour le craft, les coffres, les fours, le
  creusage, la pose et les portes ;
- résilience des coroutines de métiers et délais basés sur le temps moteur ;
- harnais Luanti pour le cœur, le spawn, les logements, les fours et les portes.

### Validation observée

- Luanti 5.17.0, serveur headless ;
- Minetest Game officiel au commit
  `c42e4d0c0ff9d27ff7b9b308c3cfc14098dd3a0f` ;
- copie isolée de VoxeLibre 0.92.1 et installation locale avec correction de
  l'ordre de dépendances `vl_hudbars` / `mcl_gamemode` ;
- création et rechargement du cœur et du spawn dans les deux profils ;
- aucun `ERROR`, `FATAL` ou `ModError` dans les journaux finaux retenus.

### Limites bloquantes

- aucun parcours avec client graphique ;
- aucune économie autonome complète de bout en bout ;
- aucun scénario réel à deux joueurs et deux villages ;
- aucune validation d'une installation VoxeLibre intacte ;
- lint et workflows distants non observés.
