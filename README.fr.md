# Scripts RP — serveur Night City (générés via le Devkit MCP)

> Plan complet v2 : `PLAN.html` à la racine du dépôt.

**Depuis le 18 septembre au soir, tout le serveur vit dans le vrai Night City.** Le plateau
d'eval des Badlands a disparu : le spawn freeroam est **Kabuki Market Centre**
(`-1191.30, 2006.88, 7.82`, Watson), chaque point d'intérêt est un lieu réel mesuré (points
marchés à pied, intérieurs AMM), habillé de vrais props, et les cinq logements sont de vrais
appartements avec leur porte. La section « Carte de Night City » plus bas donne tous les
lieux avec leurs coordonnées ; les `README.md` de chaque ressource (tables « Where things
are » et parcours « Test in 2 minutes ») font foi pour le détail.

Cinq ressources serveur écrites par des agents qui n'avaient **que** `@open2077/mcp` 0.1.2
(pas le dépôt, pas le web, pas d'accès serveur), validées par `open77_validate` pour le build
`2.31.13+op77.76`, chargées sur le serveur d'eval et vérifiées au moins depuis la console.
Chaque dossier a son `README.md` (commandes + « tester en 2 minutes »).

| Ressource | Commandes | Ce que ça fait |
|---|---|---|
| `rp_economy` | `/money`, `/pay <id> <montant>`, `/givemoney <id> <montant>` (admin), `/payday` (admin) | Portefeuille persistant (500 €$ au départ, paie automatique +200 €$ / 10 min), **en SQL depuis le 18 septembre** (`rp_economy_wallets`, migration automatique de l'ancien KVP, repli KVP sans base), exports `getBalance/add/remove` pour les autres ressources |
| `rp_jobs` (v1) | `/jobs`, `/job <livreur\|taxi\|mecano\|medecin\|police>`, `/job quit`, `/mission`, `/stopmission` | Un métier par joueur, persistant. `/mission` (livreur) : spawn d'une MaiMai à côté de toi, 3 points de livraison avec waypoint GPS, +150 €$ par colis — **remplacé par `rp_jobs` v2 en phase 2** (`/mission` retiré, le run de livraison est celui de `rp_nomade`) |
| `rp_shop` | `/shop`, `/buy <objet>`, `/sell [hella\|quadra]` | Boutique en menu : `soin` 50, `stim` 30, `armure` 150, `pistolet` 400, `fusil` 1200, `katana` 900, `hella` 15000, `quadra` 60000 ; les véhicules se revendent à 50 % — **remplacée par `rp_shops` en phase 3** (ne pas charger les deux) |
| `rp_chat` | `/me`, `/do`, `/ooc`, `/w <id> <texte>`, `/dice [faces]`, `/showid [id]` | Chat RP de proximité (30 m, murmure 10 m), carte d'identité avec métier et solde |
| `eval_taxi` | `/taxi`, `/taxi cancel` | Taxi PNJ : chauffeur visible (`Character.NightlifeMaleDriver`), 90 km/h, répliques vocales + chat ; destination posée sur la route (courtes distances seulement, voir le diagnostic IA véhicule) |
| `rp_medic` | `/soin <id>`, `/reanimer <id>` (médecins), `/911 <message>`, `/medic` | Soins payants (100 / 300 €$ au médecin), appel d'urgence, liste des médecins — **absorbé par `rp_trauma` en phase 2**, retiré du serveur |

Note : `/heal` et `/revive` existaient déjà (menu admin, freeroam) — les verbes médecin sont
donc `/soin` et `/reanimer`.


## Phase 1 — le socle (livrée le 18 septembre, jouée avec un client agent)

Quatre ressources SQL (MariaDB `open77-rp-mariadb` sur `127.0.0.1:13390`, base `open77_rp`,
connexion injectée par `%LOCALAPPDATA%\Temp\op77-eval-run\start-server.ps1`, jamais dans une
ressource). Toutes chargées ensemble sur le serveur d'eval, testées de bout en bout le 18 au
matin avec un client agent (joueur « Vince Kovac »).

| Ressource | Commandes | Ce que ça fait |
|---|---|---|
| `rp_identity` | formulaire NCID à l'arrivée, `/carte`, `/civil <id> …` (admin), ALT+clic → « Show ID » | État civil persistant (prénom, nom, naissance, sexe, origine), citoyen n°, nameplate au nom RP. Exports `get fullName isRegistered`, événement `rp_identity:changed` |
| `rp_inventory` | `/inv`, `/use <objet>`, `/drop <objet> [n]`, `/ramasser`, `/give <id> <objet> [n]`, `/fouiller <id>`, `/saisir <id> <objet>`, `/giveitem <id> <objet> [n]` (admin/console), ALT+clic → « Give item » / « Search pockets » | Poches à poids (40 kg), 17 objets définis dans `shared/items.lua` (eau, burrito, Nicola, bidon CHOOH2, bandage, MaxDoc, Bounce Back, lockpick, ferraille, composants, synthcoke…). **`/inv` ouvre le panneau WebUI POCKETS** (tuiles, barre de poids, Use / Give / Drop ; repli en liste chat sans WebUI) ; objets lâchés = loot au sol ramassable, coffres partagés par export `openStash` (même panneau à deux colonnes). Exports `has add remove count list openStash`, événements `rp_inventory:changed/used` |
| `rp_bank` | `/bank` (à un distributeur : 5 POI avec pin de carte et invite **E**), `/solde`, `/virement <id> <montant>` (frais 1 %), `/societe` | Compte séparé du liquide, dépôt / retrait / virement / relevé (10 dernières opérations), comptes de société pour les métiers. Les cinq ATM sont de vrais lieux (trois sur Kabuki Market, un dans l'Afterlife, un chez Vik) avec une borne-terminal spawnée à côté de l'anneau. Exports `getAccount deposit withdraw transfer society societyAdd societyRemove`, événement `rp_bank:changed` |
| `rp_needs` | `/needs`, `/setneeds <id> <faim> <soif> <fatigue>` (admin) | Faim / soif / fatigue qui baissent avec le temps, avertissements à 25 %, malus de santé / endurance à 0 %, remontées par les consommables de `rp_inventory`. Exports `get consume`, événement `rp_needs:changed` |

### Parcours de test phase 1 (5 minutes)

1. Première connexion : le créateur de personnage natif (base SQL activée), puis le formulaire
   **Night City citizen registration** (prénom, nom, date `AAAA-MM-JJ`, sexe, origine) →
   `Welcome to Night City, <nom>. Citizen #n`. `/carte` réaffiche la carte ; ALT+clic sur un
   joueur → « Show ID » la lui montre.
2. `/solde` → `Cash: 500 €$ · Account: 0 €$`. Marche 3 m à l'est du spawn jusqu'à l'anneau
   **ATM — Kabuki Market** (`-1188.3, 2006.9`, une borne-terminal à côté, pin sur la carte,
   invite `E  Use the ATM` à moins de 3 m, il faut le regarder) ou `/bank` : dépose 300,
   retire 100, ouvre le relevé. `/virement <id> 50` vers un autre joueur (frais 1 €$). À 10 m,
   `/bank` répond `No ATM within 3 m` (le suivant est à Noodle Row, 25 m au nord-est).
3. Depuis la console Warden (ou en jeu avec les droits admin) : `giveitem <ton id> burrito 2`,
   `giveitem <ton id> water 1`, `giveitem <ton id> synthcoke 1`. `/inv` : le panneau **POCKETS**
   s'ouvre (barre de poids, une tuile par objet, l'illégal en rouge) ; clique le burrito →
   **Use** (3 s, faim +35) ; l'eau → **Drop** → un loot apparaît à tes pieds → `/ramasser` (ou
   l'invite native « Take »). Échap referme le panneau.
4. `/needs` → `BIOMONITOR Hunger 97% | Thirst 95% | Fatigue 98%`. `setneeds <id> 10 10 10`
   depuis la console pour voir les avertissements, `0 0 0` pour les malus.
5. À deux joueurs : `/give <id> water` (ou le bouton **Give** du panneau, actif à moins de 3 m),
   `/fouiller <id>` (la cible doit être menottée ou les mains en l'air — `/rp.held`),
   `/saisir <id> synthcoke`, `/virement`.

Vérifié en SQL après chaque étape : `rp_identity_citizens`, `rp_bank_accounts` +
`rp_bank_transactions`, `rp_inventory_items`, `rp_needs_state` (les valeurs survivent à un
`restart` de la ressource et à une reconnexion).

Pièges rencontrés : l'invite **E** d'un POI `open77_worldui` n'est active qu'à `radius + 0,5 m`
par défaut et en le regardant (`requireLookAt`) — `rp_bank` passe `promptDistance = 3` ; les
étiquettes 3D des distributeurs se dessinent par-dessus les fenêtres UI kit (cosmétique, côté
plateforme) ; un serveur avec base SQL envoie toute identité neuve dans le créateur natif, que
l'entrée synthétique ne sait pas terminer — pour un client agent, semer une ligne
`open77_characters` + `open77_player_appearances` (copie d'un profil existant) suffit.


## Phase 2 — les métiers (livrée le 18 septembre, jouée en solo avec un client agent)

Treize ressources : `rp_jobs` v2 (douze métiers, grades, service, société, paie), `rp_zones`
(zones nommées, safe zone, événements), puis un métier = une ressource. Toutes SQL, toutes
démarrent ensemble sur le serveur d'eval avec les phases 0 et 1 (`rp_medic` est retiré :
`rp_trauma` l'absorbe). Les positions sont de **vrais lieux de Night City** : le hub est
Kabuki Market (Watson, le spawn) ; l'Afterlife, Lizzie's, la clinique de Vik et le
Megabuilding H10 sont à quelques centaines de mètres au sud dans le même district streamé ;
les Badlands gardent les nomades (camp Aldecaldos) et la casse (Rancho Coronado) ; Westbrook
la concession ; le NCPD siège dans son vrai bâtiment du centre-ville (les flics roulent).

| Ressource | Commandes | Prouvé en jeu le 18 sept |
|---|---|---|
| `rp_jobs` v2 | `/jobs /job /service /agence /embaucher /virer /promouvoir`, `setjob <id> <métier\|none> [grade]` (console/admin) | setjob → /service → /job → menu de l'agence (POI E sur **The Gallery**, la passerelle au nord de Kabuki Market, `-1173.12, 2087.44`, 83 m du spawn, borne-terminal derrière l'anneau) ; société amorcée à 50 000 €$ au premier patron ; paie toutes les 10 min |
| `rp_zones` | `/zones /zone` | onze zones (`kabuki_market` safe r 70, `kabuki` district, `afterlife` r 50, `lizzies`, `h10`, `viktor_clinic`, `ncpd_hq`, `junkyard`, `nomad_camp`, `westbrook_dealer`, `badlands` = polygone à l'est de x 900) ; toasts d'entrée, « Out of NCPD coverage » dans les Badlands, arbitre de dégâts en safe zone ; pins + anneaux |
| `rp_ncpd` | `/menotter /demenotter /escorter /fouille [saisir] /amende [payer] /embarquer /prison /liberer /casier /mandat /ncpd [texte]` + ALT+clic | HQ / cellule / bureau dans la **salle de conférence du vrai bâtiment NCPD** (centre-ville, `-1761.5, -1010.8, 94.3`, 3,1 km au sud) ; avant-poste de patrouille sur la rue de l'Afterlife (`-1408, 960`, holo NCPD + barrière) ; /ncpd, radio ; canal voix « NCPD dispatch » ; le reste attend un suspect |
| `rp_trauma` | `/soin /reanimer /911 /medic /respawn /trauma [av\|factures\|payer] /contrat` + ALT+clic Stabilise/Revive | /suicide → « DOWN » 60 s (gel, santé 5 %, entrées bloquées, compte à rebours) → /respawn **chez Vik** (`-1546, 1231`, « tu te réveilles chez Viktor »), 500 €$ ; AV Trauma sur le pad de la rue de l'Afterlife (`-1408, 960`, r 15) |
| `rp_delamain` | `/delamain [annuler\|afterlife\|afterlife_lot\|dealer\|lizzies] /accepter /course /fin /note` | appel sans chauffeur → repli « /taxi » ; presets = rue de l'Afterlife, parking de l'Afterlife, concession Westbrook, Lizzie's ; course complète à deux joueurs |
| `rp_mecano` | `/reparer /remorquer /peindre /facture [ok\|non] /fourriere [registre] /plein` + ALT+clic véhicule | atelier sur la **rue de l'Afterlife** (`-1396, 966`, enseigne + deux bloque-pneus), pompe CHOOH2 6 m plus loin (prop pompe), fourrière = casse ; réparation 0,4 → 1,0 (2 composants), plein 60 L, peinture rouge, remorquage accroché (6 m derrière) |
| `rp_ferrailleur` | invites E sur 7 épaves + PNJ Rusty, `/ferraille /vendre` | **casse de Rancho Coronado** (`1374.9, -1674.9`, 4,5 km au sud-est) : Rusty à `1368, -1676`, sept anneaux parmi les vraies épaves, props (bidon, pneu, tôle) ; achat du pied-de-biche 250 €$ → fouille accroupie 8 s → +1 puce → vente 288 €$ (10 % société) |
| `rp_nomade` | POI « Aldecaldos contracts board », `/convoi [annuler] /convois /camp`, prompts sur le camion (charger / décharger / rendre) | **camp Aldecaldos** (tableau `1790, 2252, 180.3`, caisses cargo, baie du camion `1800, 2240`), destinations casse / rue de l'Afterlife / Drive-In ; contrat 3 caisses → Mackinaw → caisse en main (prop attaché) → chargée → embuscade Wraiths vers `1600, 600` ; déchargement à jouer au volant |
| `rp_bar` | POI « The Afterlife - bar counter », `/bar /servir` + ALT+clic Serve a drink | comptoir = **le vrai bar de l'Afterlife** (`-1451.5, 1012.5, 17.8`, un bot y a tenu debout le 18) ; réassort ×3 depuis la caisse → bière mixée (4 s) → `/use beer` : soif +25, ivresse 1 |
| `rp_ripperdoc` | POI « Vik's chair », `/operer /ripper /implants` + ALT+clic Operate | chaise = **la clinique de Viktor** (`-1548, 1230, 11.6`, bot vérifié à l'intérieur), zone `viktor_clinic` r 12 ; catalogue 5 implants, boîtes définies ; opération à deux joueurs |
| `rp_fixer` | POI « Fixer's board », `/gigs /gig [abandonner] /fixer [publier <gabarit>]` | tableau dans la **salle de réunion de Rogue** au fond de l'Afterlife (`-1436.8, 977`, borne-terminal) ; objectifs à Noodle Row, Lizzie's, H10, la casse ; 6 gigs publiés, acceptation d'une escorte (blip objectif), abandon (réputation) |
| `rp_netrunner` | `/netrun [deck …] /ping /court_circuit /surchauffe /brouiller /breach` + ALT+clic | point d'accès = **arrière-salle de l'Afterlife** (`-1419.9, 989.4`, borne-terminal) ; statut (implant, quickhacks, cooldowns), brouillage 60 s ; hacks sur joueur à deux |
| `rp_vigile` | `/garde [engager\|fin\|journal] /expulser` + ALT+clic | contrats de zone `afterlife`, `lizzies`, `kabuki_market` ; « Guard The Afterlife » pris, +16 €$/min au vigile, +4 à la société, payé par la société du bar |

Les preuves de la colonne datent de la matinée, sur l'ancien plateau ; après le déménagement de
l'après-midi, `selftest` (33/33 PASS, toutes phases) et les contrôles console ont été rejoués
sur les nouvelles positions — les parcours en jeu ci-dessous sont à rejouer à Night City.

### Parcours de test phase 2 (15 minutes, un joueur ; « 2 » = second joueur utile)

Tu pars du spawn, Kabuki Market Centre. Les ruelles du marché sont **piétonnes** : pour une
voiture, sors par South Gate (`-1218, 1950`, 63 m au sud-ouest), ou téléporte-toi depuis la
console (`tp <id> x y z`).

1. Console : `setjob <id> ncpd 3` puis `/service`, `/job`, `/jobs`, `/ncpd`, `/ncpd unit 1 on patrol`.
   Marche 83 m au nord-est jusqu'à **The Gallery** (passe The Arch, monte les marches ;
   `-1173, 2087`) : E → menu des métiers civils. **2** : `/embaucher`, `/menotter`,
   `/fouille`, `/amende` (le suspect accepte ou refuse), `/prison <id> 2` (le prisonnier est
   téléporté dans la cellule du bâtiment NCPD, centre-ville, `-1755.5, -1010.8, 94.3`, 3,1 km
   au sud ; `/liberer` le ramène au bureau).
2. `/suicide` → écran « DOWN … /respawn opens in 60 s » (gel, santé 5 %) → après 60 s `/respawn`
   → réveil **chez Vik** (`-1546, 1231`, 855 m au sud-ouest, toast *Vik's Clinic*), 500 €$
   facturés, l'ATM de la clinique à 3 m. **2** : un médecin en service voit le blip et fait
   ALT+clic → Revive (300 €$, gratuit avec `/contrat`). Médecin en service sur la rue de
   l'Afterlife (`-1408, 960`) : `/trauma av` → l'AV apparaît devant toi.
3. `setjob <id> mecano 1`, `giveitem <id> toolkit 1`, `giveitem <id> component 4`, `giveitem <id> chooh2 1`,
   `giveitem <id> paint_can 1` ; va sur la **rue de l'Afterlife** (`-1396, 966`, 1,1 km au sud,
   ou `tp <id> -1396 966 23.6`) : `/car` puis console `vehicle.health <véhicule> 0.4` →
   `/reparer` (15 s), `/plein` à la pompe, `/peindre red` ; second `/car`, monte dans le
   premier, `/remorquer` → l'autre suit à 6 m. `/fourriere` ne marche qu'à la casse.
4. `setjob <id> ferrailleur 1` → en voiture jusqu'à la **casse de Rancho Coronado**
   (`1374.9, -1674.9`, 4,5 km au sud-est, toasts *Badlands* puis *Junkyard*) : E sur Rusty
   (`1368, -1676`, près du bidon) → **Buy a crowbar** → E sur une épave (accroupi 8 s) → E sur
   Rusty → **Sell scrap** (ou `/vendre`).
5. `setjob <id> nomade 1` → **camp Aldecaldos** (`1790, 2252`, 3 km à l'est ; `tp <id> 1790 2252
   180.3`) : E sur le tableau entre les deux caisses → contrat *Scav parts run* → E sur une
   caisse (points de chargement 4–6 m au nord) → E sur le Mackinaw (baie `1800, 2240`) « Load
   the crate » ×3 → route des Badlands vers la casse (~4 km) : embuscade Wraiths vers
   `1600, 600` → E « Unload » dans l'anneau de la casse → paie → retour au camp « Return the
   truck ».
6. `setjob <id> barman 3` → **comptoir de l'Afterlife** (`-1451.5, 1012.5`, 1 km au sud ; `tp <id>
   -1453 1017 16.6` sur le plancher du bar) : `/bar` → **Restock** ×3 → **Recipes** → Beer →
   `/use beer`. **2** : ALT+clic sur un client → Serve a drink (il accepte, paie 30 €$).
7. `/gigs` à la **salle de réunion de Rogue** (fond de l'Afterlife, `-1436.8, 977`) → accepte
   « Meds run » (Noodle Row `-1178.7, 2028.5` → casse), suis le blip, E aux deux points.
   `setjob <id> vigile 1` → `/garde` → **Guard The Afterlife** → reste dans l'anneau du bar
   2 min → `/garde` (gains) → `/garde journal`.
8. `setjob <id> netrunner 1`, `giveitem <id> qh_jammer 1`, `giveitem <id> chip 1` → `/netrun` →
   `/brouiller` (60 s) → E sur le terminal de l'**arrière-salle de l'Afterlife** (`-1419.9,
   989.4`) « Access point » → `/breach`. **2** : `/ping <id>`, `/court_circuit <id>` (deck
   requis : `/netrun deck short_circuit`).
9. `setjob <id> ripper 1` → **chaise de Vik** (`-1548, 1230` ; `tp <id> -1545 1233 11.6` sur
   l'entrée de la clinique) : **2** : le patient s'allonge (E), le ripper ALT+clic → Operate →
   devis accepté → opération.

Trouvailles plateforme de la phase 2 (dans base #33 et les rapports d'agents) : un commandement
console de plus de ~40 arguments tuait le serveur (pile Lua non réservée — corrigé, testé) ; la phase
de vie « dead » arrive à la connexion et à chaque téléport admin (`cause=script`,
`weapon=open77_admin:tp`), une mort RP doit filtrer ; `open77_interactions` n'a pas de native
d'attache véhicule→véhicule (remorquage par `setTransform`) ; les tâches `npcs.tasks.attack` sur un
joueur en véhicule répondent `invocation_failed` (l'attitude hostile suffit) ; les étiquettes
worldui se dessinent au-dessus des dialogues UI kit ; `open77_zones` plafonne un rayon à 2 000 m
(`invalid_radius`), d'où le polygone pour les Badlands.

## Phase 3 — le monde (livrée le 18 septembre, jouée en solo avec un client agent)

Trois ressources SQL sur les vraies rues : garages sur la rue de l'Afterlife et concession à
Westbrook, cinq vrais appartements avec leur porte réelle, cinq stands de Kabuki Market avec
vendeurs PNJ et props de marché.

| Ressource | Commandes | Prouvé en jeu le 18 sept |
|---|---|---|
| `rp_garage` | `/concession`, `/garage`, `/cles [id\|revoke]`, `/verrouiller`, `/plaque` ; anneaux **E** garage public **Afterlife street lot** (`-1408, 960`, baies `-1412 / -1406 / -1400, 968` face au nord, enseigne garage), garage mécano (`-1396, 966`), concession **Westbrook Motors** (`-1442.2, 127.4`, cadre néon ; la voiture apparaît sur la grille de course `-1450.2, 119.9`), fourrière = casse | achat d'une Arch Nazare (plaque NC-9TX3), `/plaque`, véhicule perdu (retiré du monde → de retour au garage en 30 s), sortie au garage public, rangement avec carburant (60 L) et état conservés en SQL (`rp_garage_vehicles`, `rp_garage_keys`) ; exports `ownerOf hasKey plateOf vehiclesOf spawnOwned impound setWanted` |
| `rp_shops` | `/boutiques`, `/acheter <id> [n]` ; 5 stands de Kabuki Market avec vendeur PNJ et prop : supermarché **Noodle Row** (Rosa, `-1178.7, 2028.5`, étagère), pharmacie **Med-Point — The Stalls** (Dr. Osei, `-1223.9, 1989.5`, distributeur, tenue par `trauma`), armurerie **2nd Amendment — East Row** (Wilson, `-1160.5, 2019.1`, râtelier), vêtements **Jinguji Threads — Vendor Lane** (Kimiko, `-1212.3, 1978.5`, mannequin), marché noir **Lower Walkway Dealer** (Dex, `-1201.1, 2035.6`, sous le marché, caisse, 22 h–6 h) | eau ×2, licence d'arme (500 €$, `rp_shops_licences`), Lexington (400 €$, arme livrée en main), braquage par `rp_crime` (375 €$) ; stock et ventes en SQL ; exports `openShop stock rob` |
| `rp_housing` | `/agence_immo` (**Night City Real Estate**, The Crossing `-1218.65, 2022.93`, borne-terminal), `/maison [cles\|retirer\|spawn\|vendre\|acheter]`, `/loyer [payer]` ; **5 vrais appartements** : No-Tell Motel (chambre Venus, Kabuki) 9 000, Glen (Heywood) 15 000, V's Apartment / Megabuilding H10 25 000, Judy's (Kabuki) 30 000, Japantown 40 000 ; la porte est la vraie porte du logement, trouvée via `open77_doors` (« auto door », repli intérieur + 3 m tant qu'un client n'a pas streamé l'étage) + intérieur + coffre + « Front door » en anneaux **E** | achat du No-Tell Motel (9 000 €$ ; était le Northside DLC, retiré le 18/09 au soir : crash moteur plateforme, voir pièges), `/maison`, trois loyers de 500 €$ prélevés à la paie, puis (après le correctif base #35) E sur la porte → intérieur, E sur le coffre → pied-de-biche rangé (`rp_inventory_stashes`), E sur *Front door* → dehors, `/maison spawn`, `/loyer payer` (`rp_housing_homes`, `rp_housing_keys`) ; porte réelle de H10 découverte et anneau déplacé (`auto door of h10_studio: 0x…`) ; exports `homeOf isInside stashOf hasKey` |

## Phase 4 — immersion, outils et vie criminelle (livrée le 18 septembre)

| Ressource | Commandes | Prouvé en jeu le 18 sept |
|---|---|---|
| `rp_hud` | `/interface` (masquer) | HUD WebUI : nom RP + id, liquide, compte, métier/grade/service, faim/soif/fatigue, zone (`KABUKI MARKET safe` au spawn), heure et météo serveur ; visible sur toutes les captures, placé à 260 px au-dessus des widgets vanilla |
| `rp_radio` | `/radio <fréquence>`, `/radio dire <texte>`, `/radio off` (objet `radio` requis) | `/radio 95.5`, message relayé sur le canal, fréquence relue depuis SQL (`rp_radio_tuning`), `/radio off` persistant ; brouillage par `rp_netrunner:jammed` ; coupure Badlands désactivée par défaut (`badlandsCut`) ; export `channelOf` |
| `rp_phone` | `/tel` (WebUI contacts / SMS / annonces), `/sms <numéro\|id> <texte>`, `/contacts`, `/annonce` (objet `phone` requis) | numéro 555-0001 attribué à la première connexion, téléphone ouvert, annonce ; tables `rp_phone_lines/contacts/sms/ads` ; exports `numberOf sms contactsOf broadcast`. SMS entre joueurs = **2** |
| `rp_mdt` | `/mdt`, `/mdt fermer` (NCPD ou Trauma en service) | tablette WebUI NCPD : recherche « Vince » → fiche (identité, mandat, amendes, casier, véhicules, contrat Trauma), ajout d'une entrée au casier (`rp_ncpd:addRecord`, ligne SQL) ; onglets véhicules, rapports (`rp_mdt_reports`), dispatch, traces réseau |
| `rp_gangs` | `/gang creer\|inviter\|quitter\|infos\|vendre`, `/territoire`, `/racket`, `/guerre`, `/setgang` (admin) | 4 territoires sur les zones : `kabuki_market` (acheteur Maelstrom à **Far Corner** `-1149, 2055` + caisse), `lizzies` (acheteur dedans), `junkyard` (acheteur `1370, -1670`), `afterlife` (sans acheteur, seulement disputé) ; `/gang creer maelstrom`, `/gang vendre` (+1 influence, `rp_gangs_influence`), tribut +50 €$ ; exports `gangOf rankOf isBoss influence addInfluence`. Guerre / racket = **2** |
| `rp_crime` | `/braquer`, `/crocheter`, `/dealer <id>`, `/voler`, `/receler` (**Vik the Fence** à la casse, `1381, -1668`, entre deux caisses, 22 h–6 h) | recel de 2 pièces volées (600 €$), crochetage d'une Archer Hella verrouillée (12 s, alerte NCPD, APB), braquage du marché de Noodle Row arme au poing (20 s, 375 €$, alerte + casier) ; les cinq boutiques braquables = les stands de `rp_shops` ; `rp_crime_log` ; export `wantedVehicles`. `/dealer`, `/voler` (caisses du camp Aldecaldos) = **2** |
| `rp_ambiance` | `/ambiance [weather\|time\|siren\|notice\|reload]`, console `ambiance reload` | cycle jour/nuit (3 h réelles), météo toutes les 12–24 min, 10 figurants PNJ en 4 zones (`kabuki_market` 3, `afterlife` 3, `lizzies` 2, `junkyard` 2), boucles sonores à l'Afterlife et chez Lizzie's, annonces ; 8 réglages surchargés par `rp_config` (`realHoursPerDay` 2 h appliqué puis retiré) |

## Phase 5 — administration et exploitation (livrée le 18 septembre)

| Ressource | Commandes | Prouvé le 18 sept |
|---|---|---|
| `rp_admin` | `/rpadmin`, `/warn`, `/freeze`, `/spectate`, `/setmoney`, `/setbank`, `/setgrade`, `/report <texte>`, `/tickets` (ACL `command.rpadmin`) | `warn` depuis la console (joueur averti, `rp_admin_actions`), tickets ; `RpAdminConfig.Spawn` = Kabuki Market Centre ; événement `rp_admin:action` repris par `rp_logs`. Freeze / spectate sur un tiers = owner |
| `rp_logs` | `/logs [n] [filtre]`, console `logs` | 51+ événements `rp_*` relus depuis SQL (`rp_logs_events`) après restart ; exports `log query` (MDT) ; webhook Discord lu dans l'environnement, jamais dans la ressource. Correctif : l'acteur console (id 0) tuait la VM (`Open77.players.identifier(0)` lève) |
| `rp_whitelist` | `/wl statut\|ajouter\|retirer\|ban\|unban\|liste`, console `wl` | `wl statut` (désactivée, mode allowlist, SQL `rp_whitelist_entries/bans`) ; `wl ban 2 3 …` → reconnexion du bot refusée (`server_reject_6: Banned from Night City for 3 min …`), `wl unban` → reconnexion acceptée ; exports `isAllowed ban`. Allowlist activée = owner |
| `rp_config` | `/config get\|set\|unset\|list\|reload\|export` (ACL `command.config`, console) | 706 clés / 29 sections, **resynchronisées le 18 après le déménagement** (positions, noms de zones, ATM, prix des logements) ; set / get / refus de type / branche (`rp_ncpd.cell`) / list / export, surcharge SQL (`rp_config_values`) appliquée par `ambiance reload`, unset ; exports `get set unset reload all`, lus en `pcall` par `rp_ambiance`, `rp_radio`, `rp_crime` (`tools/migrate-configs.md` pour migrer les autres) |

### Parcours de test phases 3–5 (15 minutes, un joueur ; « 2 » = second joueur utile)

1. Console : `givemoney <id> 30000`. Va à **Westbrook Motors** (`-1442.2, 127.4`, 1,9 km au sud ;
   `tp <id> -1442 127 18.1`) : le cadre néon marque l'anneau, E ou `/concession` → Arch Nazare
   → *Buy* ; la moto apparaît sur la grille de course 11 m au sud-ouest. `/plaque` à côté.
   Roule (ou `tp <id> -1408 960 23.5`) jusqu'à l'**Afterlife street lot** (`-1408, 960`,
   l'enseigne garage marque l'anneau), descends, E ou `/garage` → *Store* ; rouvre → *Take out*
   (première baie libre `-1412, 968`). `/cles`. **2** : `/cles <id2>` puis `/verrouiller` par
   le second joueur ; le garage mécano est 12 m à l'est (`-1396, 966`).
2. Anneau **Night City Real Estate** à The Crossing (`-1218.65, 2022.93`, 32 m à l'ouest du
   spawn, borne-terminal à côté) : E → *No-Tell Motel - room Venus* → *Sign*. `/maison`, `/loyer`.
   No-Tell Motel (`-1202.2, 1333.2, 20.0`, Kabuki, 675 m au sud ; `tp <id> -1202.2 1333.2 20.0`) :
   l'anneau est sur la vraie porte dès qu'elle est découverte (`auto door` dans le log), sinon
   à intérieur + 3 m : E → fondu, intérieur ; E sur *Stash* (coffre `rp_inventory`), écarte-toi
   de plus de 3,4 m du coffre, E sur *Front door*. `/maison spawn` puis reconnexion → réveil chez
   soi.
3. Vendeurs de Kabuki Market : **Rosa** à Noodle Row (`-1178.7, 2028.5`, 25 m au nord-est, à
   l'étagère) : E → eau ; **Wilson** à East Row (`-1160.5, 2019.1`, au râtelier) : `/acheter
   licence` puis `/acheter pistol` (arme en main) ; **Kimiko** à Vendor Lane → *Styling session*
   (garde-robe) ; **Dex** au Lower Walkway (escalier sous le marché, `-1201.1, 2035.6, z 5.6`)
   après `weather.time.set 23:00`. `/boutiques`.
4. `/tel` (numéro affiché), `/annonce Selling a Hella, cheap`, `/radio 95.5`, `/radio dire Anyone
   copy?`. **2** : `/sms <numéro2> Meet me at the Afterlife`.
5. Console `setjob <id> ncpd 3`, `/service`, `/mdt` : cherche ton nom, ouvre la fiche, ajoute une
   entrée au casier, onglet *Dispatch* ; `/mdt fermer`.
6. `/gang creer maelstrom`, `/territoire`, console `giveitem <id> drug_pack 2`, marche 64 m au
   nord-est jusqu'à **Far Corner** (`-1149, 2055`) : E sur l'acheteur Maelstrom (ou `/gang
   vendre`) → +80 €$, influence +1. **2** : `/gang inviter <id2>`, `/racket`, `/guerre junkyard`.
7. Crime : arme sortie devant Rosa → `/braquer` (20 s, l'officier en service est alerté).
   Console `giveitem <id> lockpick 1`, une voiture verrouillée d'autrui à 4 m → `/crocheter`.
   Console `giveitem <id> stolen_parts 2`, casse de Rancho Coronado entre 22 h et 6 h (heure
   serveur, HUD ; `weather.time.set 23:00`) → **Vik the Fence** (`1381, -1668`, entre deux
   caisses) → E ou `/receler`. **2** : `/dealer <id2>` (il accepte), `/voler` sur une caisse
   nomade au camp Aldecaldos.
8. Console : `warn <id> Keep it clean`, `logs 8`, `wl statut`, `config get rp_bank.transferFeePercent`,
   `config set rp_ambiance.realHoursPerDay 2`, `ambiance reload`, `config unset rp_ambiance.realHoursPerDay`.
   `/report Stuck in the junkyard` puis `/tickets` (admin).

### Piège plateforme découvert le 18 septembre : le budget script client divise par le nombre de ressources

Le client donne 2 000 µs par frame aux scripts Lua, **divisés par le nombre de ressources en
cours d'exécution** (plancher 50 µs) ; toute reprise qui atteint 10 000 instructions est tuée
si son tranche est dépassée, et une boucle `CreateThread` qui lève une erreur est retirée pour
toute la session. Avec ~70 ressources client (45 plateforme + 39 RP), `open77_interactions`
(les prompts **E**) et `open77_contextmenu` (ALT+clic) meurent quelques secondes après chaque
connexion ou swap (`… script execution budget exceeded` dans `red4ext/logs/open77-*.log`) : les
cartes s'affichent encore, mais rien ne se déclenche. Fix base : PR #35 (plancher de tranche 300 µs
dans l'hôte + boucle `open77_interactions` en phases sous `pcall` + registre contextmenu linéaire) ;
la moitié Lua est déployée sur le serveur d'eval (plus aucun `budget exceeded`, `15 context actions
registered`, prompts E rejoués : porte, coffre, sortie du logement), la moitié C++ attend un
rebuild + déploiement client quand le jeu du owner est fermé.

Une règle de jeu qui en découle : deux anneaux **E** à moins de 3 m l'un de l'autre — le premier
« accroché » garde le focus tant qu'il reste à portée (hystérésis de `open77_interactions`) ;
le coffre et la porte d'entrée d'un logement sont à 3 m, il faut s'écarter du coffre pour voir
la porte.

Deux autres règles de déploiement payées cette nuit : après avoir recopié un fichier livré au
client (`shared/`, `client/`, `web/`), faire `refresh` **puis** `restart <nom>` (un `restart`
seul renvoie l'ancien paquet) ; et une ressource dont le manifeste est livré au client (dès
qu'elle a un `shared_script`) ne doit pas déclarer `dependency` vers une ressource sans moitié
client — le client rejette alors **tout** le jeu de ressources (`rp_crime:missing_dependency:rp_economy`).

Trois limites de plus, mesurées le 18 au soir en habillant Night City de props :

- **La requête monde côté client n'est pas prouvée sur 2.31** (`Open77.world.nearby` répond
  `part_layout_not_proven`) : impossible de lier une invite aux vrais distributeurs, ATM ou
  bornes du jeu par classe. Les anneaux sont donc posés aux coordonnées mesurées et les bornes
  sont des props spawnés à côté. Base PR #37 décode la disposition des parts ; PR #35 (budget)
  reste le prérequis pour que les invites tiennent.
- **Un `.mesh` brut passé à `Open77.props.create` se rend en dalle blanche.** Seuls les alias
  curés du catalogue de la plateforme se rendent correctement — parcmètre pour un ATM, moniteur
  pour les tableaux (emploi, fixer, immobilier, point d'accès), étagère de marché, râtelier
  d'armes, distributeur, pompe à essence, bloque-pneus, barrières, caisses cargo, ferraille —
  c'est ce que toutes les ressources utilisent (permission `world.props`, création au start,
  retrait au stop, un refus ne fait que logger).
- **La carte d'invite ne sait pas dessiner un tiret cadratin** (—) : les libellés d'invite
  écrivent « - » (`The Afterlife - bar counter`, `E - Fixer's board`).

### Piège plateforme découvert le 18 septembre au soir : l'appartement Northside (DLC) crashe le jeu

Entrer dans le Northside Apartment (`-1503.8, 2224.9, 22.2`) et regarder les objets posés sur la
table (un jus de tomate, deux autres consommables) tue le client en quelques secondes :
`0xC0000005` à `Cyberpunk2077.exe+0x53F9D4`, `+0x1458DF` ou `+0x142F17` — cinq reproductions
le 18/09, trois sites de faute, **une seule corruption du tas** (une cellule de 8 octets
`PoolRefCount` de l'allocateur slab moteur est libérée puis un compteur de références y est
encore incrémenté : `{strong=2, weak=-2}`). Les trois objets de la table sont respawnés
~24 fois dans les 18 s qui précèdent chaque faute. **Ce n'est pas une ressource RP** : la
5e reproduction a eu lieu avec les trois cibles `open77_interactions` du monde (fence, acheteur
de gang, camion nomade) désactivées, sans une seule requête `world.` dans le journal, et le
propriétaire confirme que le crash précède les scripts RP. Piste principale côté base : les
wraps de suppression du loot multijoueur (`gameItemDropObject.IsContainer` → `false`), qui
tournent dès que la politique multijoueur est active. Base PR #38 (branche
`fix/apartment-interior-crash`) : root cause prouvée, garde `bindable` sur `OnItemEntitySpawned`
(plus de handle fort ni de `BindNative` sur le décor), fuite de weak-refs de `world.nearby`
corrigée, breadcrumbs dans le loot, recette A/B documentée dans
`docs/research/loot-ground-items.md` — **pas encore construit ni déployé** (exige l'arrêt du
jeu). Conséquences RP : `northside_container` est devenu la chambre Venus du No-Tell Motel
(Kabuki, marchée 45 s sans mal) ; les prompts natifs fence / acheteur / camion sont pilotés par
`nativePrompt(s)` dans les configs (remis à `true` une fois la piste écartée) ; éviter tout
intérieur avec du décor lootable jusqu'au correctif base.

### Passe « animations, props, durées » du 18 septembre au soir

Verdict du owner en test : « pas d'anim, on ne voit pas l'objet dans les mains », les actions
métier étaient instantanées. Depuis, **toute action qui manipule quelque chose joue une pose du
catalogue `open77_animations` du serveur, montre un prop attaché au corps quand ça a un sens, et
dure derrière la barre UI kit** (X annule ; la barre immobilise côté client, le serveur ne gèle
jamais). Tout est piloté serveur (`Open77.animations.play/stop`, `Open77.props.create/attach/
remove`), donc visible par les autres joueurs. Le motif est celui de la pose de portage de
`rp_nomade` : dans chaque `shared/config.lua` un bloc `Stage` (`RpCrimeConfig.stage`,
`RpPhoneConfig.anim` pour le téléphone ; `SHOP_STAGE` / `NEEDS_STAGE` / `MEDIC_STAGE` en tête du
`server/main.lua` des trois ressources sans config partagée) avec, par action, une **liste de
profils essayés dans l'ordre** via `Open77.animations.get` (le nom du futur catalogue à 76
profils de la PR base d'abord — `repair`, `scavenge`, `laptop`, `bottle`, `takeout`, `call`,
`handsback`, `carry_pickup`… — puis ce que le catalogue d'eval à 18 profils a aujourd'hui :
`examine`, `give`, `phone`, `drink`, `handsup`, `wounded`, `think`, `smoke`), une liste d'alias de
props (`tool.welder`, `container.gas_can`, `food.bourbon`, `medical.device`, `crate.ammo_box`,
`military.case`, `electronics.monitor`, `garbage.bag`…) avec `bone` / `offset` / `rotation`, et
une durée. Un refus (profil inconnu, `player_in_vehicle`, `animation_owned`, attache refusée) est
loggé une fois et ne bloque jamais l'action. Dix-huit ressources touchées (`rp_mecano`,
`rp_ferrailleur`, `rp_bar`, `rp_ripperdoc`, `rp_medic`, `rp_trauma`, `rp_ncpd`, `rp_netrunner`,
`rp_crime`, `rp_gangs`, `rp_fixer`, `rp_delamain`, `rp_shops`, `rp_shop`, `rp_bank`, `rp_needs`,
`rp_housing`, `rp_phone`), chacune validée (`open77_validate` + `--lint`) et documentée dans son
README, section « Staging » (table action → pose → prop → durée, et les lignes de log
`stage` / `gesture` / `hold` à attendre). Non vérifié sans le jeu : le rendu des attaches de main
(axes des slots non mesurés sur 2.31, partir de zéro et bouger un axe à la fois), la pose
`wounded` sur un corps gelé (rp_trauma), la pose `handsup` sur un suspect déjà tenu par le kit
(`animation_owned` attendu et inoffensif), et le doublon de prop quand les profils futurs qui
livrent leur propre objet (`laptop`, `takeout`, `repair`) arriveront — retirer alors la ligne
`prop` concernée.

### Nuit du 19 septembre : preuve bot du convoi nomade, couches d'animation, saccades

Pile déployée = base `main` c77df814 (PR #30–#43 fusionnées : budget script, pile Lua, loot,
couches d'animation `carry`/gestes, stutter du hôte de ressources, coût de `open77_interactions`,
port en première personne, `firstPerson` sur `props.attach`), serveur + client + archives.
Rejoué **par le bot** (`open77_client_launch` + console) : `/service`, `/convoi` → plateau →
contrat « CHOOH2 barrels » → E caisse (clip `carry_pickup`, caisse à plat dans les mains) →
19 m à pied avec la caisse (`anim=idle_bodycarry_sync_upperbody`, `workspot=no` pendant la
marche) → E camion (caisse visible dans le plateau, slot 1 puis 2) → route GPS sur la minimap
(phase `destination`, puis `return` avec « 9.4 km ») → E *Unload* (caisses posées au sol une par
une) → +300 €$, +45 société → E *Return the truck* → caution remboursée, contrat #13 clos.
Journal serveur : `picked up crate 1/2 … attached:Chest pose=carry`, `loaded crate … bed slot 1,
attached to truck`, `delivered crate 1/2 (putdown 2400ms, on the ground …)`, `returned the truck,
deposit refunded`.

Trouvé et corrigé au passage : (1) le point de livraison « Afterlife street » était SUR l'anneau
du garage → le prompt du garage volait le E du camion ; déplacé 20 m plus haut (`-1426, 974`).
(2) La perte de PV « mystérieuse » de la soirée = `rp_needs` : nourriture/eau à 0 après des
heures en ligne → 1 PV / 10 s jusqu'à 10 ; le HUD affichait « HUNGER 0 % », lu comme « pas
faim » → étiquettes **Food / Water / Energy** (satiété). (3) Console lab `aplay <pid> <profil>`,
`astop`, `vwarp <véhicule> x y z` dans `rp_worldprobe`, et il journalise chaque changement
d'état d'animation.

Côté plateforme, mesuré : plus aucun `watcher pass cost` (0 en 30 min), hôte serveur 260–300
µs/frame (pics 1,2 ms) contre 13 468 µs avant, 77–84 Hz ; `open77_interactions` 15–19 µs/frame
sans cible monde. **Encore ouvert** : (a) ~~la requête monde native coûtait 41 ms par appel~~ → réglé par base PR #44/#45 : une cible
`globalNpc` restreinte aux PNJ Open77 (`npcs = "open77"`, ou une règle `record`) se résout depuis
le registre sans requête monde ; fence et acheteur de gang sont revenus à `nativePrompt = true`
(mesuré : 1,6 ms/s, aucune requête) ; (b) la banque 26 clips des gestes
(`smoke_walk`, `point`…) n'est pas chargée par le moteur (A/B : avec elle, aucune couche ne
joue ; avec la banque 2 clips, `carry` joue) → l'archive installée garde la banque 2 clips, les
gestes attendent le correctif de base ; (c) l'épingle/route GPS de la phase `destination` n'a été
vue que sur la minimap en phase `return` (à confirmer sur la carte Open77) ; (d) la première
personne (bras + `firstPerson` de la caisse) n'a pas été regardée par le bot.

## Carte de Night City

Toutes les positions en mètres monde, relevées le 18 septembre (points marchés à pied par le bot,
intérieurs AMM, rues sondées) ; distances à vol d'oiseau depuis le spawn. Les valeurs de
référence sont les `shared/config.lua` et les README de chaque ressource.

**Kabuki Market, Watson — le hub (spawn freeroam `-1191.30, 2006.88, 7.82`, safe zone r 70)**

| POI | Ressource | Position | Depuis le spawn |
|---|---|---|---|
| ATM — Kabuki Market (borne) | `rp_bank` | `-1188.30, 2006.88, 7.82` | 3 m E |
| ATM — Noodle Row | `rp_bank` | `-1178.66, 2028.45, 7.95` | 25 m NE |
| ATM — Kabuki South Gate | `rp_bank` | `-1218.13, 1950.17, 7.98` | 63 m SO (côté rue, voitures) |
| Supermarché Noodle Row (Rosa) | `rp_shops` / `rp_crime` | `-1178.66, 2028.45, 7.95` | 25 m NE |
| Pharmacie Med-Point — The Stalls (Dr. Osei) | `rp_shops` | `-1223.91, 1989.45, 7.98` | 37 m SO |
| Armurerie 2nd Amendment — East Row (Wilson) | `rp_shops` | `-1160.50, 2019.06, 7.76` | 33 m E |
| Vêtements Jinguji Threads — Vendor Lane (Kimiko) | `rp_shops` | `-1212.26, 1978.53, 7.98` | 35 m SO |
| Marché noir Lower Walkway (Dex, 22 h–6 h) | `rp_shops` | `-1201.07, 2035.60, 5.60` | 30 m N, sous le marché |
| Agence pour l'emploi — The Gallery (borne) | `rp_jobs` | `-1173.12, 2087.44, 11.94` | 83 m NE, passerelle (hors safe zone) |
| Night City Real Estate — The Crossing (borne) | `rp_housing` | `-1218.65, 2022.93, 7.82` | 32 m O |
| Acheteur de gang — Far Corner (caisse) | `rp_gangs` | `-1149.22, 2054.84, 7.76` | 64 m NE |
| Figurants du marché | `rp_ambiance` | autour du centre | 0 m |

**Watson sud — l'Afterlife, Lizzie's, Vik, H10**

| POI | Ressource | Position | Depuis le spawn |
|---|---|---|---|
| Zone `afterlife` (r 50) — plancher du bar | `rp_zones` | `-1453, 1017, 16.6` | 1,0 km SSO |
| Comptoir de l'Afterlife | `rp_bar` | `-1451.5, 1012.5, 17.8` | — |
| ATM — The Afterlife (escalier d'entrée) | `rp_bank` | `-1447.0, 1022.0, 16.6` | — |
| Bureau du fixer — salle de réunion de Rogue (borne) | `rp_fixer` | `-1436.8, 977.0, 17.0` | — |
| Point d'accès — arrière-salle (borne) | `rp_netrunner` | `-1419.9, 989.4, 16.6` | — |
| Parking de l'Afterlife (preset `afterlife_lot`) | `rp_delamain` | `-1440.0, 1035.0, 22.7` | — |
| **Rue de l'Afterlife** (passage piéton devant la rampe) : garage public *Afterlife street lot* (enseigne), baies `-1412 / -1406 / -1400, 968` | `rp_garage` | `-1408, 960, 23.5` | 1,07 km SSO |
| Rue de l'Afterlife : pad de l'AV Trauma (r 15) | `rp_trauma` | `-1408, 960, 23.5` | — |
| Rue de l'Afterlife : avant-poste NCPD (holo + barrière) | `rp_ncpd` | `-1408, 960, 23.6` | — |
| Rue de l'Afterlife : preset taxi `afterlife`, destination de convoi `afterlife_street` | `rp_delamain` / `rp_nomade` | `-1408, 960, 23.5` | — |
| Rue de l'Afterlife : atelier mécano (enseigne, bloque-pneus) + garage de société | `rp_mecano` / `rp_garage` | `-1396, 966, 23.5` | 12 m E du garage public |
| Rue de l'Afterlife : pompe CHOOH2 (prop pompe) | `rp_mecano` | `-1390, 972, 23.5` | — |
| Lizzie's Bar (zone `lizzies` r 18 ; acheteur de gang dedans `-1185, 1568, 23`) | `rp_zones` / `rp_gangs` / `rp_delamain` / `rp_fixer` | `-1188.9, 1566.2, 22.9` | 440 m S |
| Clinique de Viktor — la chaise (zone `viktor_clinic` r 12) | `rp_ripperdoc` | `-1548.0, 1230.0, 11.6` | 855 m SO |
| Clinique de Viktor — réveil Trauma (« l'hôpital ») | `rp_trauma` | `-1546, 1231, 11.6` | — |
| ATM — Vik's Clinic (entrée) | `rp_bank` | `-1545.0, 1233.0, 11.6` | — |
| Megabuilding H10 — V's Apartment (zone `h10` r 45 ; logement `h10_studio` 25 000 €$, porte réelle `-1389.2, 1268.4`) | `rp_housing` / `rp_fixer` | `-1391.9, 1271.7, 123.1` | 760 m SO |

**Logements (rp_housing, intérieur AMM ; la porte réelle est trouvée à chaud via `open77_doors`)**

| Logement | Id | Intérieur | Prix | Depuis le spawn |
|---|---|---|---|---|
| No-Tell Motel - chambre Venus (Kabuki) | `northside_container` | `-1202.2, 1333.2, 20.0` | 9 000 €$ | 675 m S |
| Glen Apartment (Heywood) | `badlands_hideout` | `-1524.0, -992.6, 9.1` | 15 000 €$ | 3 km S |
| V's Apartment — Megabuilding H10 | `h10_studio` | `-1391.9, 1271.7, 123.1` | 25 000 €$ | 760 m SO |
| Judy's Apartment (Kabuki) | `kabuki_flat` | `-906.3, 1868.7, 42.4` | 30 000 €$ | 320 m E |
| Japantown Apartment (Westbrook) | `japantown_loft` | `-785.3, 992.6, 12.0` | 40 000 €$ | 1,1 km SE |

**Ailleurs en ville**

| POI | Ressource | Position | Depuis le spawn |
|---|---|---|---|
| NCPD — salle de conférence du vrai bâtiment (zone `ncpd_hq` r 30) ; cellule 6 m à l'est `-1755.5, -1010.8`, bureau 4 m au nord `-1761.5, -1006.8` | `rp_ncpd` | `-1761.5, -1010.8, 94.3` | 3,1 km S (centre-ville) |
| Westbrook Motors — concession (cadre néon ; zone `westbrook_dealer` r 40 ; preset taxi `dealer`) | `rp_garage` / `rp_delamain` | `-1442.2, 127.4, 18.0` | 1,9 km S |
| Grille de course de Westbrook — la voiture achetée apparaît là | `rp_garage` | `-1450.2, 119.9, 14.8` | — |
| Drive-In Theater (destination de convoi `drive_in`, r 40, sans zone) | `rp_nomade` | `-81.2, 1963.3, 100.8` | 1,1 km E |

**Badlands (zone `badlands` = polygone à l'est de x 900, « Out of NCPD coverage »)**

| POI | Ressource | Position | Depuis le spawn |
|---|---|---|---|
| Casse de Rancho Coronado (zone `junkyard` r 90) ; 7 épaves à moins de 17 m du centre | `rp_zones` / `rp_ferrailleur` | `1374.9, -1674.9, 49.3` | 4,5 km SE |
| Rusty, le ferrailleur (bidon à côté) | `rp_ferrailleur` | `1368.0, -1676.0, 49.4` | — |
| Vik the Fence (deux caisses, 22 h–6 h) | `rp_crime` | `1381, -1668, 49.4` | — |
| Acheteur de gang — junkyard | `rp_gangs` | `1370, -1670, 49.4` | — |
| Fourrière / dépôt de remorquage | `rp_mecano` / `rp_garage` | `1370, -1680, 49.3` | — |
| Camp Aldecaldos — tente de V (zone `nomad_camp` r 120) | `rp_zones` | `1792.9, 2248.9, 180.2` | 3,0 km E |
| Tableau des contrats (deux caisses cargo) ; points de chargement 4–6 m au nord | `rp_nomade` | `1790.0, 2252.0, 180.3` | — |
| Baie du camion Mackinaw | `rp_nomade` | `1800.0, 2240.0, 180.2` | — |
| Cercle d'embuscade (r 60, sur la route camp → casse ; à affiner au `groundz`) | `rp_nomade` | `1600, 600` | — |

Trois ressources partagent le même point `-1408, 960` sur la rue de l'Afterlife (anneau E du
garage public, pad de l'AV Trauma r 15, anneau muet de l'avant-poste NCPD) et les baies du
garage sont à l'intérieur du rayon du pad : seul le garage a une invite à presser, mais faire
apparaître l'AV avec des voitures sorties du garage est à éviter.

## Récapitulatif au 18 septembre au soir

**Ce qui marche (joué par le client agent, tout en SQL, 89 ressources chargées ensemble sur
`127.0.0.1:11798` après un redémarrage à froid sans erreur)** : les 39 ressources RP des phases
0 à 5 — état civil, poches (panneau WebUI POCKETS), banque, besoins, douze métiers avec leurs
runs, zones, NCPD, Trauma, taxi, mécano, ferrailleur, nomades, bar, ripperdoc, fixer, netrunner,
vigile, garage (achat / perte / sortie / rangement), logements (achat, loyer, porte, coffre,
sortie, spawn), commerces (licence + arme), HUD, radio, téléphone, MDT (fiche + casier), gangs
(création + deal), crime (recel, crochetage, braquage), ambiance, admin (warn, tickets), audit
SQL, whitelist (ban → reconnexion refusée → unban), config centrale (surcharge appliquée à chaud).

**Fait dans l'après-midi et la soirée du 18** : le déménagement complet vers Night City (spawn
Kabuki Market, toutes les positions, zones, presets et libellés ; la carte ci-dessus), les
props réels sur chaque POI extérieur (alias curés du catalogue), les cinq vrais appartements
avec porte réelle revendiquée via `open77_doors`, `/inv` en panneau WebUI, les portefeuilles
`rp_economy` en SQL, une revue de code qui a corrigé une trentaine de défauts (acteur console
id 0 qui plantait, ids de joueur en chaîne venus des événements hôte, `await` de base de données
manquants, `source` périmé après un `await` UI, balayage des véhicules perdus, blocage de la
whitelist sur la base, persistance de `/radio off`, TTL du camion nomade…), et `selftest` qui
couvre désormais toutes les phases (33/33 PASS).

**Ce qui reste au owner** : rejouer les parcours en jeu sur les nouvelles positions (les preuves
des tableaux datent du plateau du matin), les parcours à deux joueurs (clés de véhicule et de
logement, SMS, `/embaucher`, menottes / fouille / amende, revive par un médecin, escorte du
vigile, guerre et racket de gang, `/dealer`, `/voler`, freeze / spectate, allowlist activée), les
trajets en voiture (convoi nomade camp → casse avec l'embuscade, taxi joueur, remorquage), le
caps des yaws non mesurés (baie du camion, grille de Westbrook), la migration des constantes
vers `rp_config` (`rp_config/tools/migrate-configs.md`), le webhook Discord de `rp_logs`
(convar côté opérateur), et un redémarrage de son client quand il le souhaite.

**Ce qui reste plateforme (PR ouvertes dans base, à merger par le owner)** : #30 routage IA
véhicule, #32 et #34 corrections de cartes MCP phases 1–2, #33 réservation de pile Lua (prouvé en
live), #35 budget script client (moitié Lua prouvée en live sur l'eval, moitié C++ à rebuild +
déployer jeu fermé), #36 docs phases 3–5 (limites de la passerelle SQL, `players.identifier(0)`,
`state.write`, guide WebUI, dépendances livrées au client, `refresh`/`restart`), **#37 décodage
de la disposition des parts pour la requête monde** (`Open77.world.nearby`, aujourd'hui
`part_layout_not_proven` sur 2.31 : sans lui, pas d'invite sur les vrais ATM / distributeurs du
jeu) ; devkit #3 (validateur 0.1.3, `.await` / `MySQL`) puis publication npm 0.1.3 ; après le
merge de #36, ajouter le catalogue `npc-records` (6 668 `Character.*`) à la description de
l'outil `open77_data` du devkit et régénérer l'index. Ordre de merge des PR docs : #32 → #34 →
#36 (empilées). Défauts plateforme sans PR : `Open77.players.identifier(0)` qui tue la VM au lieu
de répondre nil, pas d'API d'environnement pour les ressources, quota d'ancres natives (32)
inférieur au nombre de prompts d'un serveur RP (les cartes au-delà ne se dessinent que quand
elles gagnent l'arbitrage), rayon de zone plafonné à 2 000 m, un `.mesh` brut rendu en dalle
blanche, pas de tiret cadratin sur les cartes d'invite.

## Lancer une session de test

Le serveur d'eval tourne en tâche de fond sur ce poste : `127.0.0.1:11798` (freeroam +
les 39 ressources RP des phases 0 à 5 + `eval_taxi` `/taxi`), Warden sur
`http://127.0.0.1:11800`, journal `%LOCALAPPDATA%\Temp\op77-eval-run\server-taxi.log`.
Ton identité (w0dm4n) a tous les droits ACL dessus, donc `/givemoney <ton id> 100000` marche.
**Le spawn est Kabuki Market Centre** (`-1191.30, 2006.88, 7.82`, Watson) : tu arrives dans la
safe zone du marché, les stands, les ATM, l'agence pour l'emploi et l'agence immobilière sont à
moins de 90 m ; le reste se rejoint en voiture (sortie par South Gate, `-1218, 1950`), par
`/delamain`, ou depuis la console Warden avec `tp <id> x y z`.

Le plus simple : dire à Claude « lance le client sur le serveur RP ». À la main :

```powershell
pwsh -File C:\Games\cyberm\base\scripts\agent-play.ps1 up -DevLocal
pwsh -File C:\Games\cyberm\base\scripts\agent-play.ps1 connect -Endpoint 127.0.0.1:11798
```

Si le serveur ne répond plus (`Get-NetUDPEndpoint -LocalPort 11798` vide), le relancer :

```powershell
pwsh -File $env:LOCALAPPDATA\Temp\op77-eval-run\start-server.ps1   # injecte la connexion SQL depuis db.env
```

Les ressources sont chargées depuis `%LOCALAPPDATA%\Temp\op77-eval-run\resources\` (copie
de ce dossier) ; après une modification ici, recopier puis `refresh` + `restart <nom>` dans la
console Warden.

## Parcours de test conseillé (10 minutes, un seul joueur — phase 0, historique)

Ce parcours date de la phase 0 ; sur le serveur actuel `/mission` (rp_jobs v2), `/shop` (remplacé
par `rp_shops`) et `/job medecin` (rp_medic absorbé par `rp_trauma`) n'existent plus — utiliser
les parcours des phases 1 à 5 ci-dessus. Il reste valable sur un serveur qui ne charge que les
ressources de la phase 0.

1. À l'arrivée : le chat affiche `Solde : 500 €$`. `/money`, puis `/givemoney <ton id> 100000`
   (ton id est dans `/id` ou dans les messages du chat).
2. `/jobs` → `/job livreur` → `/mission` : une voiture apparaît à côté, un waypoint GPS pointe
   la première livraison ; à chaque arrivée `Colis n/3 livré !` et `+150 €$`. `/stopmission`
   pour arrêter, `/job quit` pour démissionner.
3. `/shop` → `/buy soin`, `/buy katana` (livré par le relais armes), `/buy hella` (la voiture
   apparaît à ta droite), `/sell hella` (7 500 €$ rendus).
4. `/me regarde autour de lui`, `/do Il pleut.`, `/dice 20`, `/showid`, `/ooc salut`.
5. `/job medecin` puis `/medic` (liste), `/911 test` (0 intervenant tant que tu es seul).
   `/soin` et `/reanimer` demandent un second joueur à moins de 5 m.

## Ce qui n'a pas pu être vérifié cette nuit

Tout ce qui demande un joueur en jeu (la mission de livraison, les achats, le chat de
proximité, les soins) n'a été vérifié qu'en lecture de code et depuis la console serveur ;
les exports croisés (`rp_selftest`, désormais 33 contrôles sur toutes les phases, 33/33 PASS)
et le démarrage des ressources sont vérifiés sur le serveur. Les points à surveiller en
priorité sont dans la section « À vérifier » plus bas, mise à jour au fil de la nuit.

## À vérifier en priorité (lecture de code, pas encore joué)

- `rp_jobs` v1 : la MaiMai apparaît à `x + 4 m` avec ton cap (`heading` non documenté en unité) ;
  les points de livraison réutilisent ton `z` — un point peut tomber dans un bâtiment ou en
  contrebas, l'arrivée compte à 12 m **en 2D** donc ça reste atteignable. Le waypoint GPS est
  posé par le petit script client (`Open77.blips.setWaypoint`). (Retiré de la v2.)
- `rp_shop` : les armes passent par le relais `open77_weapons` (réponse « Livré » asynchrone,
  remboursement automatique après 15 s sans réponse) ; le véhicule apparaît à 3,5 m à droite
  (sens de rotation du cap deviné : si elle apparaît à gauche, c'est juste le signe).
- `rp_chat` : le rendu `auteur : texte` dépend de l'UI du chat (l'auteur est un tag court :
  `RP`, `OOC`, `Murmure`, `Dé`, `ID`). La portée 30 m utilise `Open77.players.nearby`.
- `rp_medic` : `/reanimer` utilise `Open77.players.revive` (santé 1.0, 5 s de grâce) — jamais
  observé en jeu ici ; `/soin` refuse un patient déjà à pleine santé. (Absorbé par `rp_trauma`.)
- `rp_economy` : la paie automatique tombe toutes les 10 min (`Paie : +200 €$`) ; les soldes
  vivent en SQL (`rp_economy_wallets`) et survivent à une reconnexion et à un redéploiement ;
  seul un démarrage sans base retombe sur le KVP local (`store=kvp reason=…` dans le log), et
  ces soldes-là ne sont pas refusionnés en SQL ensuite.
- Sur les nouvelles positions : un anneau posé sous le sol (z AMM trop bas) « réussit » sans
  rien afficher — `/pos` sur place et coller la hauteur dans le `config.lua` ; les yaws de la
  baie du camion nomade et de la grille de Westbrook n'ont pas été mesurés dans le sens de la
  route.

Journal serveur : chaque action laisse une ligne grep-able (`[rp_economy] +150 player 1
livraison balance=…`, `[rp_jobs] payroll player 2 ncpd grade=3 +800`, `[rp_shops] sale
shop=gunshop …`, `[rp_trauma] player 3 down at …`).


## Diagnostic IA véhicule (18 septembre)

`rp_taxitest` (console admin : `taxitest near|nearride|nearenter|traffic|mapz|far|legs|legsride <id> [x y z]`, `taxitest stop`) a mesuré que `Open77.vehicles.ai.driveTo` ne roule que vers un point de route court et atteignable dans le monde streamé (20 m validés : arrivée en 5 s) ; un point lointain, hors voie, ou `joinTraffic` laissent la tâche `running` sans mouvement. Traces dans `devkit/evals/rp-round/`. `eval_taxi` détecte maintenant l'absence de route (odomètre < 3 m après 12 s) et le dit au passager ; le vrai correctif est côté plateforme (branche `fix/vehicle-ai-routing` dans base). `groundz <id> <x> <y>` du même outil donne la surface sous un point à moins de 80 m d'un joueur connecté (il ment sous les surplombs : préférer les points marchés / AMM).
