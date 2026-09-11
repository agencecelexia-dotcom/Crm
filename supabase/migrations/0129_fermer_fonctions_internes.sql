-- Ferme l'accès public aux fonctions internes.
--
-- LE PROBLÈME
--
-- PostgreSQL rend toute nouvelle fonction exécutable par PUBLIC — donc par la
-- clé `anon`, qui est publique par construction : elle est servie dans le
-- bundle du site. Une fonction n'est fermée que si sa migration écrit
-- explicitement `revoke execute … from public`.
--
-- Les fonctions du portail artisan le font toutes. Les mécaniques internes du
-- pont (0126), les enveloppes de cron (0107) et `inviter_commercial` (0108) ne
-- le faisaient pas. Vérifié en production avec la seule clé publique :
--
--   * `pont_chantier_json(id)` renvoyait nom, téléphone, e-mail et adresse du
--     client d'une affectation, SANS AUCUN JETON. Un identifiant suffisait.
--   * `pont_enfiler(...)` permettait de glisser un faux événement dans la file
--     de sortie — que nous aurions ensuite SIGNÉ de notre secret et livré au
--     CRM de l'artisan comme authentique.
--   * `inviter_commercial(...)` faisait confiance à l'identifiant de fondateur
--     FOURNI PAR L'APPELANT : quiconque le connaissait pouvait créer un compte
--     commercial.
--   * les `*_si_actif()` permettaient à n'importe qui de déclencher à volonté
--     les relances et rappels par e-mail.
--
-- Les identifiants sont des UUID aléatoires, non devinables : ces failles
-- demandaient de connaître un identifiant. Mais la sécurité d'une donnée
-- client ne doit pas reposer sur le secret d'un identifiant — les jetons du
-- portail existent précisément pour ça.
--
-- LE PRINCIPE RETENU
--
-- Fermé par défaut, ouvert explicitement. Une fonction appelée par la clé
-- publique doit le déclarer dans sa propre migration ; les autres sont
-- internes, et ne sont appelées que par des déclencheurs ou fonctions
-- `security definer` — qui s'exécutent avec les droits du propriétaire et ne
-- sont donc pas affectées par ce retrait.

-- ---------- 1) Mécaniques internes : plus personne ne les appelle directement ----------
--
-- Retirées à `authenticated` aussi : un commercial connecté n'a pas plus de
-- raison qu'un anonyme de forger un événement ou de lire un chantier par son
-- identifiant brut. Leurs seuls appelants sont `security definer` (vérifié :
-- trg_pont_affectation, trg_pont_suivi, pont_tester, pont_etat_evenement,
-- pont_tick) ou pg_cron, qui tourne en propriétaire.

revoke execute on function public.pont_chantier_json(uuid)                 from public, anon, authenticated;
revoke execute on function public.pont_enfiler(uuid, text, jsonb)          from public, anon, authenticated;
revoke execute on function public.pont_ouvert(uuid)                        from public, anon, authenticated;
revoke execute on function public.pont_tick()                              from public, anon, authenticated;
revoke execute on function public.livrer_pont_sortant()                    from public, anon, authenticated;
revoke execute on function public.reconcilier_pont_sortant()               from public, anon, authenticated;

revoke execute on function public.rafraichir_taches_si_actif()             from public, anon, authenticated;
revoke execute on function public.surveiller_coherence_si_actif()          from public, anon, authenticated;
revoke execute on function public.traiter_rappels_si_actif()               from public, anon, authenticated;
revoke execute on function public.traiter_recontacts_si_actif()            from public, anon, authenticated;

-- ---------- 2) Assistants de lecture : fermés au public seulement ----------
--
-- `peut_abandonner_affectation` est appelée par `trg_garde_fou_abandon`, un
-- déclencheur `security INVOKER` : il s'exécute avec les droits de celui qui
-- écrit. Un compte connecté qui modifie une affectation doit donc garder le
-- droit de l'appeler, sinon son écriture échouerait. On ne la retire qu'à la
-- clé publique, qui n'écrit jamais directement dans `affectations`.

revoke execute on function public.peut_abandonner_affectation(uuid)        from public, anon;
revoke execute on function public.derive_etape_affectation(uuid)           from public, anon;
revoke execute on function public.calculer_origine(uuid)                   from public, anon;

grant execute on function public.peut_abandonner_affectation(uuid)         to authenticated;
grant execute on function public.derive_etape_affectation(uuid)            to authenticated;
grant execute on function public.calculer_origine(uuid)                    to authenticated;

-- ---------- 3) Créer un commercial : ne plus croire l'appelant sur parole ----------
--
-- 0108 avait introduit `p_invite_par` parce que `auth.uid()` est vide quand
-- l'edge function appelle en service_role. Le paramètre était accepté quel que
-- soit l'appelant : un anonyme, ou un commercial connecté qui voit les
-- identifiants de fondateurs sur les chantiers, pouvait s'en servir.
--
-- Il n'est désormais cru QUE si l'appel vient du service_role — c'est-à-dire
-- de l'edge function `inviter-membre`, seul appelant légitime.

create or replace function public.inviter_commercial(
  p_user_id uuid,
  p_email text,
  p_nom text,
  -- Valeur par défaut conservée à l'identique : PostgreSQL refuse qu'un
  -- `create or replace` retire un défaut existant.
  p_taux numeric default 0.10,
  p_invite_par uuid default null
)
returns json
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_id uuid;
  v_auteur uuid;
begin
  -- L'identifiant transmis n'est cru que du service_role. Pour tout autre
  -- appelant, seul le JWT fait foi.
  v_auteur := case
    when auth.role() = 'service_role' then p_invite_par
    else auth.uid()
  end;

  if v_auteur is null then
    return json_build_object('ok', false, 'error', 'reserve_fondateur');
  end if;

  -- Le rôle est revérifié en base, dans tous les cas.
  if not exists (
    select 1 from public.membres
    where user_id = v_auteur and role = 'fondateur' and actif
  ) then
    return json_build_object('ok', false, 'error', 'reserve_fondateur');
  end if;

  if coalesce(btrim(p_nom), '') = '' then
    return json_build_object('ok', false, 'error', 'nom_requis');
  end if;
  if p_taux < 0 or p_taux > 1 then
    return json_build_object('ok', false, 'error', 'taux_invalide');
  end if;

  insert into public.membres (user_id, role, nom, email, taux_retrocession, invite_par)
  values (p_user_id, 'commercial', btrim(p_nom), lower(btrim(p_email)), p_taux, v_auteur)
  on conflict (user_id) do update
    set nom = excluded.nom, email = excluded.email,
        taux_retrocession = excluded.taux_retrocession, actif = true
  returning id into v_id;

  -- L'e-mail d'invitation est pilotable depuis l'écran d'automatisations
  -- (famille « E-mails externes »), comme toute automatisation du CRM.
  if public.automatisation_active('auto_mail_invitation') then
    perform net.http_post(
      url := 'https://n8n.srv1241880.hstgr.cloud/webhook/crm-celexia-events',
      body := jsonb_build_object(
        'event', 'invitation_commercial',
        'email', lower(btrim(p_email)),
        'nom',   btrim(p_nom),
        'lien',  'https://crm-ci7k.vercel.app/login'
      )
    );
  end if;

  return json_build_object('ok', true, 'membre_id', v_id);
end
$function$;

-- Seule l'edge function `inviter-membre` l'appelle, en service_role. Un
-- fondateur connecté garde l'appel direct (son JWT fait foi) ; la clé
-- publique, elle, n'a plus rien à y faire.
revoke execute on function public.inviter_commercial(uuid, text, text, numeric, uuid) from public, anon;
grant  execute on function public.inviter_commercial(uuid, text, text, numeric, uuid) to authenticated, service_role;

-- ---------- 4) Pour que ça ne se reproduise pas ----------
--
-- La cause n'est pas une migration mal écrite, c'est le défaut de PostgreSQL :
-- une fonction oubliée naît publique. On inverse le défaut pour toutes les
-- fonctions FUTURES créées par ce rôle : elles naîtront fermées au public, et
-- une fonction destinée à la clé publique devra le déclarer par un
-- `grant … to anon` explicite — ce que font déjà toutes celles du portail.
--
-- Un oubli devient ainsi un portail qui refuse bruyamment, et non plus une
-- donnée client exposée en silence. Les fonctions EXISTANTES ne sont pas
-- touchées par cette ligne.
alter default privileges for role postgres in schema public
  revoke execute on functions from public;
