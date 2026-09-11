# Pont entre l'espace artisan et le CRM de l'artisan

Un artisan travaille dans **son** outil. Le portail `/artisan/<token>` lui
demandait de ressaisir ce qu'il venait d'enregistrer chez lui — et une double
saisie n'est jamais faite sérieusement. Le pont supprime la ressaisie : nos
attributions arrivent chez lui, ses mises à jour reviennent ici.

## Ce qui existait déjà, et qu'on n'a pas réécrit

Le sens **artisan → nous** était en place depuis longtemps sans qu'on l'ait vu
comme une API :

| Fonction | Rôle |
|---|---|
| `get_espace_artisan(token)` | Tout son pipe, jetons d'affectation compris |
| `add_suivi_by_token(...)` | Déclarer une étape ou une note |
| `corriger_etape_by_token(...)` | Revenir en arrière après une erreur |
| `retirer_chantier_by_token(...)` | Abandonner, motif obligatoire |

Elles sont `security definer`, accessibles à `anon`, et portent **toutes les
règles métier** — étape monotone, correction autorisée en arrière (0118),
motif de perte imposé (0079/0114), recalcul de commission. Le pont les appelle
au lieu d'écrire en base : c'est ce qui garantit qu'une intégration partenaire
ne rouvre pas les incohérences que trois migrations ont fermées.

Il manquait le sens **nous → artisan**, et trois garde-fous : c'est l'objet de
`0126_pont_crm_artisan.sql`.

`0127_pont_actions_completes.sql` complète l'aiguillage. Le premier jet ne
couvrait que trois actions — déclarer une étape, corriger, abandonner — alors
que l'espace artisan en compte **dix**. Les sept autres (montant, devis,
rappel, appel, restauration, messages lus) n'avaient aucun chemin depuis son
CRM, ce qui l'obligeait à rouvrir le portail pour elles : soit exactement la
double saisie qu'on supprimait. Elle ajoute aussi le **test de connexion**.

### Les dix actions

| `p_type` | Équivaut dans le portail à | Délègue à |
|---|---|---|
| `statut` | les boutons d'étape | `add_suivi_by_token` |
| `note` | le fil de discussion | `add_suivi_by_token` |
| `correction` | la correction d'étape | `corriger_etape_by_token` |
| `montant` | les deux champs montant | `set_montant_by_token` |
| `devis` | les deux zones de dépôt (proposé **et signé**) | `set_devis_by_token` |
| `rappel` | le mode rappel | `definir_rappel_by_token` |
| `appel` | le bouton d'appel | `log_appel_by_token` |
| `perdu` | le retrait du chantier | `retirer_chantier_by_token` |
| `restauration` | les chantiers perdus | `restaurer_chantier_by_token` |
| `lu` | l'ouverture du fil | `marquer_lu_by_token` |

### Le devis signé, cas particulier

`trg_coherence_issue` (0120/0121) **détache** un devis signé tant que le statut
déclaré n'atteint pas `devis_signe` : « une affaire ne peut être gagnée que si
le statut atteint la signature ». Dans le portail l'artisan clique l'étape puis
dépose, donc l'ordre est respecté sans y penser. Par le pont, rien ne l'y
oblige — son document le plus important disparaîtrait en silence, l'appel
renvoyant pourtant `ok`.

`0128_pont_devis_signe.sql` rétablit l'ordre : un `montant` ou un `devis` posé
sur l'emplacement `devis_signe` déclare d'abord l'étape, puis dépose. Déposer
un devis signé DIT que l'affaire est signée.

Elle rhabille aussi le refus de `set_devis_by_token`, qui renvoyait un
`{"ok": false}` nu — sans motif, l'artisan cherche la panne là où elle n'est pas.

Aucune règle n'est recopiée : chaque type délègue. Ajouter une action au
portail demande donc d'ajouter la branche correspondante ici — sinon l'artisan
devra revenir sur le site pour elle.

## Qui fait autorité sur quoi

Tranché une fois pour toutes, sinon les données divergent en silence et on
s'en aperçoit à la facturation.

* **L'artisan** — l'avancement de son chantier : étape, montant du devis, date
  de RDV, abandon motivé.
* **L'agence** — la propriété du lead : attribution, retrait, réattribution,
  commission encaissée, suppression.

Une écriture hors périmètre est ignorée, jamais silencieusement : elle est
journalisée dans `pont_entrant`.

## Comment ça marche

### Sortant

Un déclencheur ne fait **jamais** d'appel réseau : il bloquerait la
transaction, et une panne chez l'artisan ferait échouer l'attribution du lead.
Il écrit une ligne dans `pont_sortant`, rien de plus.

`pont_tick()` (pg_cron, chaque minute) livre ce qui est dû via `pg_net`,
signé `HMAC-SHA256(corps, secret)`, puis relève les réponses dans
`net._http_response`. Échec → recul exponentiel 2, 4, 8, 16, 32, 64 minutes ;
au-delà de 6 tentatives, l'événement passe en `abandonne` et l'échec remonte
sur la fiche artisan.

Trois événements partent : `chantier_attribue`, `chantier_retire`,
`message_agence`. Son propre travail ne lui est pas renvoyé — ce serait du
bruit.

### Entrant

`pont_entrant(...)` est le point d'entrée unique. Il ne réimplémente aucune
règle : il délègue aux fonctions ci-dessus et ajoute les trois choses qui
manquaient.

**Déduplication** sur `p_evenement_id`. Son adaptateur réessaiera ; sans ça,
chaque reprise créerait un doublon de suivi.

**Rupture d'écho.** Il modifie → on reçoit → on lui renvoie → il renvoie…
Tout système bidirectionnel boucle sans coupure explicite. `pont_entrant` pose
`celexia.pont_origine = <son id>` pour la durée de la transaction ; les
déclencheurs le lisent et s'abstiennent. Le réglage porte l'identifiant et non
un simple drapeau : sur un chantier partagé, les **autres** artisans doivent
continuer d'être servis.

**Journal.** `pont_entrant` et `pont_sortant` sont lisibles sur la fiche
artisan. Sans eux, on débogue à l'aveugle le jour où ça casse.

### Livraison au moins une fois

On garantit qu'un événement finit par arriver, **pas** qu'il n'arrive qu'une
fois : un accusé perdu sur le réseau provoque un renvoi. L'adaptateur de
l'artisan doit dédupliquer sur `evenement_id` — la notice le dit en toutes
lettres, et c'est le point qu'on oublie le plus souvent.

## Brancher un artisan

1. Fiche artisan → carte **Pont vers son CRM** → activer. La clé et le secret
   sont générés par la base.
2. **Copier la notice** et la lui transmettre. Elle est déjà remplie : ses
   jetons, sa clé, son secret, nos URL. Il la colle dans son assistant de code,
   qui adapte son CRM. *On ne touche jamais à son code.*
   ⚠️ Elle contient le secret de signature — canal sûr, pas un fil public.
3. Il donne l'URL de son webhook, on la saisit. Les événements en attente
   partent alors tout seuls.
4. **Tester la connexion** — le bouton envoie un `ping` signé à son serveur et
   affiche le code HTTP qu'il renvoie. Le `ping` ne porte aucune donnée client
   et ne crée rien chez lui : il prouve le tuyau sans engager un vrai chantier.
   Tant qu'il n'est pas vert, inutile d'aller plus loin.
5. Vérifier sur la fiche : « dernier envoi réussi » doit se remplir.

Tant que l'URL est vide, rien ne part et rien ne s'accumule — le pont inactif
ne met même pas les événements en file.

## Quand ça casse

| Symptôme | Où regarder |
|---|---|
| Badge « En panne » sur la fiche | `dernier_echec` dit le code HTTP |
| Il dit avoir modifié, on n'a rien | `pont_entrant` — l'appel est-il arrivé ? |
| On a envoyé, il n'a rien reçu | `pont_sortant.code_http` |
| Doublons chez lui | Il ne déduplique pas `evenement_id` |
| Signature refusée chez lui | Secret régénéré sans qu'il soit prévenu |

## Couper

* **Un artisan** : l'interrupteur de sa fiche.
* **Tous** : écran Automatisations → *Pont vers le CRM des artisans*
  (`pont_crm_artisan`). Coupe la mise en file, la livraison et l'entrée.

## Sécurité

Le sortant est **signé** (HMAC-SHA256, secret par artisan). L'entrant
s'authentifie par le **jeton d'affectation**, comme tout le portail : un
secret de 32 caractères, propre à un chantier, révocable en retirant
l'affectation. Exiger en plus une signature à l'entrée obligerait l'artisan à
écrire un client HTTP dédié au lieu d'appeler PostgREST — cher payé pour une
sécurité que le modèle du portail assure déjà.

**Les mécaniques internes ne sont pas publiques.** `0129` a retiré à la clé
publique les fonctions internes du pont (`pont_chantier_json`, `pont_enfiler`,
la livraison, le battement) : avant elle, un identifiant d'affectation suffisait
à lire les coordonnées d'un client, et n'importe qui pouvait glisser un faux
événement que nous aurions signé. PostgreSQL rend toute nouvelle fonction
publique par défaut ; ce défaut est désormais inversé — une fonction destinée à
la clé publique doit le déclarer par un `grant … to anon` explicite.

**Nos données sortent de chez nous** : nom, téléphone et adresse du particulier
partent chez un tiers. Cela doit figurer au contrat artisan — ce n'est pas un
détail technique.
