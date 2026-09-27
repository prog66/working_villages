# Checklist de validation manuelle - autonomie (2026-09-27)

## Statut actuel

Cette checklist n'a pas encore été exécutée avec un client connecté. Toutes les
cases sont donc volontairement laissées vides.

Les preuves automatisées actuelles proviennent de serveurs Luanti headless.
Dix-neuf spécifications isolées passent sous VoxeLibre et Minetest Game,
en plus des contrôles de compatibilité, du registre et des vraies recettes
moteur de minerai. Elles couvrent notamment le chargement, la persistance du
spawn, les timers, le foyer, les portes, le stockage, le four et la comptabilité
d'inventaire. Les consultations de chantier migrent un ancien marqueur avec un
unique scan borné, puis restent sur le chemin rapide du registre.

Des harnais moteur ciblés exercent aussi la livraison physique exacte entre deux
vrais PNJ mobiles : aucun transfert à distance, reprise du rendez-vous après
redémarrage et recontrôle sans duplication. La coupe/replantation du bûcheron,
l'amorçage en bois puis l'extraction/dépôt du mineur, ainsi que la graine
naturelle, le labour et le semis du fermier passent dans les deux profils. La
récupération d'encastrement utilise dès le premier callback une position sûre
récente revalidée ; sans cache sûr, le repli local attend trois callbacks et ne
téléporte pas un mineur depuis une cavité praticable.
Le harnais physique alpha.7 ajoute trois semis réels d'un seul type planifié
malgré deux graines disponibles, le refus d'un premier terrain volontairement
humide ou occupé et le dégagement réel d'une végétation intérieure par le
constructeur, dans les deux profils. Il ne termine pas le bâtiment.
La retraite d'urgence elle-même n'est plus une zone non testée : le harnais
moteur alpha.4 exerce un vrai `on_step`, un vrai mineur et un hostile de test
dans les deux profils. Le combat et la fuite contre les mobs natifs restent en
revanche non observés avec un joueur.

Le scénario strict v12, dans un monde VoxeLibre neuf, conserve cinq PNJ au moins
273 secondes et observe un coffre commun, cinq outils, 31 arbres coupés, des
cultures semées puis mûres, une récolte et des échanges physiques. Dans ce même
scénario, aucun minerai/dépôt, cycle de four, chantier ou redémarrage n'est encore
confirmé et le verdict terminal n'est donc pas atteint. Les scénarios VoxeLibre
utilisent une copie jetable isolée dont la métadonnée de dépendance de
`vl_hudbars` a été corrigée pour contourner un problème d'ordre de chargement du
jeu. L'installation locale 0.92.1 passe le harnais principal après la même
correction, sans devenir une preuve d'installation intacte.

Les essais de village complet v17 et v18 sont des échecs diagnostiques sans
verdict terminal. V17 expire en phase 1 ; v18 a été arrêté pour diagnostic. Le
monde v19 est préparé, mais n'a pas encore été exécuté. Aucun de ces essais ne
coche une case manuelle.

Ces preuves ne valident pas :

- une installation VoxeLibre intacte ;
- le rendu, les animations, le son ou l'interface avec un vrai client ;
- une session graphique de 30 à 60 minutes dans chacun des deux jeux ;
- un cycle complet de chaque métier ;
- une économie autonome de survie de bout en bout ;
- l'équilibrage, les performances prolongées ou le plaisir de jeu.
- l'exécution d'une CI distante ou de Luacheck.

Le mod ne doit pas être déclaré « totalement compatible » ou « prêt » tant que
les deux passages obligatoires ci-dessous ne sont pas terminés.

## Matrice obligatoire

Exécuter toute la checklist dans deux mondes neufs et indépendants :

| Passage | Jeu | Installation | Mode du mod | Statut |
| --- | --- | --- | --- | --- |
| A | Minetest Game officiel | propre, sans mods de contenu ajoutés | `survival` | [ ] |
| B | VoxeLibre | propre et intacte, sans correctif local | `survival` | [ ] |

Un passage supplémentaire en `creative_test` peut servir à diagnostiquer une
construction ou une commande. Il ne remplace aucun des deux passages de survie.

## Modes, recettes et dépendances

- `working_villages_gameplay_mode = survival` est la valeur par défaut. C'est
  le seul mode qui compte pour valider la chaîne économique liée aux ressources.
- `creative_test` autorise des raccourcis de développement explicites. Il donne
  notamment un sceptre aux nouveaux joueurs et permet certains boutons/actions
  de plans. Les options de matériaux illimités ou d'expérimentation du builder
  ne sont prises en compte que dans ce mode.
- Le mode créatif du jeu, les commandes `/giveme` et le privilège `server` sont
  utiles pour préparer un scénario ciblé, mais tout objet injecté doit être noté
  et invalide un verdict d'économie autonome de bout en bout.
- Six recettes directes sont enregistrées : sceptre de commande, fiche de
  métier vide, fiche d'apprenant, botte de paille, lit agricole et pain plat
  cuit. Les autres professions n'ont pas toutes une recette directe.
- Douze plans par défaut sont enregistrés. Toute ancienne mention de dix plans
  est obsolète.
- Le runtime charge `working_villagers/loader.lua`. Le mod externe `modutil` et
  son ancien sous-module ne sont pas nécessaires au démarrage.

## Préparation commune

Pour chaque passage obligatoire :

1. Créer un monde jetable neuf et conserver son journal complet.
2. Activer uniquement le jeu, `working_villages` et les dépendances livrées avec
   le jeu.
3. Configurer `working_villages_gameplay_mode = survival` et laisser
   `working_villages_enable_spawn = true` pour le test de spawn automatique.
4. Se connecter avec un client graphique et utiliser une zone de surface
   praticable. Ne pas désactiver silencieusement les protections.
5. Relever le nom/version du jeu, la version de Luanti, tous les réglages
   `working_villages_*` modifiés et la liste des mods supplémentaires.
6. Garder une copie du monde avant chaque scénario nécessitant des objets
   injectés, afin de pouvoir revenir à un état de survie propre.

Objets de préparation selon le profil :

| Usage | Minetest Game | VoxeLibre |
| --- | --- | --- |
| Coffre | `default:chest` | `mcl_chests:chest` |
| Four | `default:furnace` | `mcl_furnaces:furnace` |
| Établi physique reconnu | aucun dans le jeu de base actuel | `mcl_crafting_table:crafting_table` |

Minetest Game ne fournit pas actuellement l'un des établis physiques recherchés
par le bootstrap (`crafting:workbench` ou `mcl_inventory:workbench`). Le moteur
de craft du profil Minetest Game n'exige pas cet établi, mais la parité visuelle
du bootstrap n'est donc pas complète. Noter l'établi « non applicable / écart
connu », et ne pas inventer un résultat positif.

## Test 1 - Spawn initial, propriété et reprise

### Spawn automatique

1. Démarrer le monde neuf avec le spawn activé.
2. Se connecter et attendre la fin de la tentative initiale.
3. Identifier les cinq villageois et leur propriétaire.
4. Arrêter proprement le serveur, redémarrer puis se reconnecter.

Résultats attendus :

- exactement cinq villageois initiaux apparaissent sur une surface valide ;
- les rôles exacts sont `woodcutter`, `farmer`, `autonome`, `miner` et
  `builder` ;
- la résolution observée suit la priorité actuelle : propriétaire déjà
  persisté, requérant d'un spawn manuel explicitement forcé, réglage
  `working_villages_initial_village_owner`, premier joueur connecté, puis
  propriétaire public `self_employed` si cette option est activée ;
- le redémarrage ne duplique pas les cinq villageois et conserve leur état.

Validation :

- [ ] cinq villageois, sans doublon
- [ ] cinq rôles exacts
- [ ] propriétaire attendu
- [ ] priorité du réglage propriétaire consignée, notamment lors du premier join
- [ ] persistance après redémarrage
- [ ] aucune erreur répétée dans le journal

### Commande de récupération `/wv_spawn5`

Tester dans une copie séparée du monde :

- en `survival`, un joueur avec le privilège `server` peut forcer le groupe ;
- sans ce privilège, la commande n'est permise qu'en `creative_test` avec un
  sceptre de commande porté ;
- le cooldown non-admin doit être respecté.

Validation :

- [ ] autorisations conformes aux deux modes
- [ ] groupe créé près du joueur sur une surface valide
- [ ] refus/cooldown explicites et sans duplication silencieuse

## Test 2 - Stockage partagé et bootstrap des utilitaires

Utiliser un monde ou une sauvegarde sans coffre, établi ni four posé à proximité.
Ne pas préremplir un coffre pour ce scénario.

1. Laisser le groupe initial agir et relever chaque changement d'état.
2. Vérifier physiquement tout coffre/four/établi posé et son propriétaire.
3. Comparer les ressources avant et après chaque fabrication ou pose.
4. Fixer une durée maximale et consigner l'état de blocage au lieu d'attendre
   indéfiniment.

Résultats attendus :

- un coffre commun est fabriqué/posé sans apparition gratuite de l'objet ;
- le coffre est enregistré comme stockage du bon village et le claim est créé ;
- un four est fabriqué/posé lorsque la phase du bootstrap le requiert ;
- dans VoxeLibre, un établi physique est fabriqué/posé ;
- dans Minetest Game de base, l'absence d'établi physique est rapportée comme
  écart de parité, sans bloquer artificiellement les recettes que le code traite
  sans station.

Validation :

- [ ] coffre commun et claim cohérents
- [ ] consommation exacte des ressources du coffre/four
- [ ] four visible et utilisable
- [ ] établi VoxeLibre visible et utilisable
- [ ] écart d'établi Minetest Game consigné
- [ ] aucune écriture dans un coffre étranger ou protégé

## Test 3 - Cuisinier et four

Ce test ciblé peut utiliser un coffre préparé ; il ne compte alors pas comme
preuve de l'économie autonome complète.

1. Définir un coffre partagé avec `/wv_storage_set here` près du coffre du
   profil actif.
2. Y déposer exactement de quoi fabriquer un four, un combustible valide et un
   objet dont la recette de cuisson produit un item du groupe `food`.
3. Assigner `cook`, retirer les fours voisins et noter les quantités initiales.
4. Attendre un cycle de cuisson réel et relever les inventaires `src`, `fuel`,
   `dst`, le stockage partagé et l'inventaire du villageois.

Résultats attendus :

- le cuisinier fabrique ou pose un four à partir de ressources réelles ;
- il alimente l'inventaire réel du four ;
- le cru et le combustible diminuent, puis le résultat revient dans le stockage
  partagé sans duplication ni perte.

Minetest Game de base ne dispose pas encore, dans les preuves automatisées,
d'un aliment cru précis confirmé pour ce scénario. Vérifier les recettes
réellement enregistrées dans le monde. Si aucune cuisson ne produit un item du
groupe `food`, noter le métier `cook` comme écart de compatibilité au lieu de
valider le test avec un objet inventé.

Validation :

- [ ] recette d'aliment cru réellement enregistrée et notée
- [ ] bootstrap du four à coût réel
- [ ] callbacks du four sans refus/erreur récurrente
- [ ] produit final récupéré une seule fois

## Test 4 - Forgeron et fonte

1. Dans une zone sans four proche, déposer dans le coffre partagé des quantités
   connues de matériaux de four, combustible et minerai métallique du profil.
2. Assigner `blacksmith` et attendre au moins un cycle de fonte complet.
3. Vérifier les inventaires du four et le retour des lingots au coffre partagé.
4. Tester ensuite, séparément, `/wv_blacksmith_order <objet> [quantite]` avec un
   objet réellement supporté par le profil.

Validation :

- [ ] four fabriqué/posé sans objet gratuit
- [ ] minerai et combustible consommés exactement
- [ ] lingots récupérés exactement une fois
- [ ] commande supportée terminée ou refus explicite et justifié
- [ ] aucune perte après redémarrage pendant un cycle

## Test 5 - Builder, porte, lit et repos

Effectuer le passage principal en `survival` avec un plan réellement appris ou
disponible et toutes les ressources nécessaires. Le bouton `Forcer tous les
plans` est réservé à `creative_test` : un résultat obtenu ainsi ne valide pas le
parcours de survie.

1. Lancer `minimal_house` ou `simple_house` avec un builder.
2. Relever les matériaux avant le chantier et à chaque étape importante.
3. Attendre l'état final `built`, puis inspecter le marqueur.
4. Vérifier la porte à deux nœuds, son ouverture par le villageois et sa
   fermeture différée après traversée.
5. Vérifier `bed position`, `position outside the house`, l'attribution du foyer
   et un vrai cycle nocturne de retour/repos.

Validation :

- [ ] chantier terminé sans matériau gratuit ni bloc fantôme
- [ ] porte complète, orientée, ouvrable et refermée
- [ ] lit réel détecté et foyer attribué au bon villageois
- [ ] accès extérieur valide
- [ ] retour au foyer et récupération d'énergie observés la nuit
- [ ] état conservé après redémarrage

### Harnais automatique associé (ne coche aucune case manuelle)

`working_villages_village_runtime_test` reproduit ce parcours avec cinq vraies
entités, une comptabilité globale des objets et deux phases séparées par un
arrêt du serveur. Il vérifie notamment que les cinq identités restent chargées,
que les ressources n'apparaissent pas ou ne disparaissent pas sans cause et que
la tâche interrompue peut être restaurée. Un succès headless de ce harnais
renforce la preuve moteur, mais ne coche aucune case de cette checklist : le
client graphique, les animations, la lisibilité et le plaisir de jeu doivent
toujours être observés humainement dans les deux profils.

État factuel du run v12 au 27 août 2026 : la première phase a prouvé le monde
neuf, cinq PNJ stables au moins 273 secondes, le coffre, cinq outils, 31 arbres,
le semis, la maturité, une récolte et des échanges physiques. Elle n'a pas
encore prouvé le minerai et son dépôt, le four, le chantier ni la deuxième phase
après redémarrage. Aucune case manuelle ci-dessus ou ci-dessous ne doit être
cochée à partir de ce résultat headless.

V17 et v18 n'ont pas remplacé cette preuve par un succès : ils restent des
échecs diagnostiques sans verdict terminal. V19 n'a pas encore été exécuté.

## Test 6 - Économie autonome de bout en bout (bloquant)

Ce test doit repartir d'un monde de survie neuf. Après la connexion initiale,
ne pas utiliser `/giveme`, ne pas poser le coffre/four/chantier à la main et ne
pas activer de raccourci `creative_test`.

Observer jusqu'à une durée maximale définie à l'avance :

1. collecte de bois et de nourriture dans le monde ;
2. création et enregistrement du stockage commun ;
3. production/obtention des outils nécessaires ;
4. alimentation et repos des villageois avec évolution cohérente des besoins ;
5. fonte ou cuisson à coût réel lorsqu'une recette compatible existe ;
6. lancement et achèvement d'un premier abri à coût réel ;
7. reprise après arrêt/redémarrage du serveur.

Pour chaque transfert, comparer le total monde + villageois + stockage + four.
Une simple présence du code, un message d'état ou un test unitaire ne valide pas
ce scénario.

Validation :

- [ ] chaîne complète observée dans Minetest Game
- [ ] chaîne complète observée dans VoxeLibre intact
- [ ] aucun objet créé ou perdu sans cause identifiée
- [ ] aucun villageois bloqué indéfiniment sans état explicite
- [ ] redémarrage sans duplication, oubli de tâche ou corruption
- [ ] rythme et interactions jugés jouables lors d'une vraie session

## Test 7 - Multijoueur, propriété et protection

Avec deux joueurs et deux villages distincts :

1. définir un stockage et un claim par propriétaire ;
2. tenter de commander, ouvrir, déplacer et approvisionner le village adverse ;
3. créer des claims proches puis chevauchants ;
4. vérifier les actions des villageois contre une zone protégée par le jeu ou un
   mod de protection explicitement listé.

Validation :

- [ ] chaque village conserve son propriétaire, stockage et inventaires
- [ ] accès adverse refusé sans sceptre/autorisation appropriée
- [ ] claims qui se chevauchent refusés ou résolus explicitement
- [ ] aucune coupe, pose, fouille ou ouverture de coffre protégée
- [ ] réglage public `working_villages_self_employed_public` testé séparément

Preuve automatique du 27 septembre 2026 : deux vrais clients Luanti 5.17
(`wv_owner_alpha` et `wv_owner_beta`) ont été connectés simultanément à
VoxeLibre. Deux villages et deux claims distincts ont été créés ; chaque
propriétaire a creusé dans son claim et les deux tentatives croisées ont été
refusées par le chemin réel `minetest.node_dig`. Marqueur terminal :
`WORKING_VILLAGES_MULTIPLAYER_PROTECTION_OK:players=2:villages=2:own_dig=allowed:cross_dig=blocked`.
Cette preuve ne couvre pas encore les claims chevauchants, l'ouverture de
coffres adverse, le sceptre ni le réglage public ; les cases manuelles restent
donc ouvertes.

## Rapport final par profil

Renseigner séparément pour Minetest Game et VoxeLibre :

- jeu/version :
- version Luanti :
- installation intacte : oui / non
- mode `working_villages_gameplay_mode` :
- réglages non par défaut :
- mods supplémentaires :
- durée réelle :
- spawn/reprise : OK / KO
- stockage/bootstrap : OK / KO / non applicable
- cuisinier : OK / KO / recette absente
- forgeron : OK / KO
- builder/porte/lit/repos : OK / KO
- économie autonome E2E : OK / KO
- multijoueur/protection : OK / KO
- erreurs ou avertissements répétés :
- captures, positions et journal :

Un `OK` global exige les deux rapports complets. Tant qu'une ligne obligatoire
est vide, la conclusion factuelle reste : **validation manuelle incomplète**.
