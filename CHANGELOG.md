# Changelog

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
