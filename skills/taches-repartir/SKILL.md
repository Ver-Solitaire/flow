---
name: taches-repartir
description: Découpe une demande en tâches et les répartit entre plusieurs Claude qui travaillent en parallèle sur plusieurs comptes (équipe FLOW) — chacun dans sa propre copie du projet, avec fusion à la fin après validation. À utiliser dès que l'utilisateur veut partager un travail entre plusieurs Claude ou plusieurs comptes — « répartis le travail », « répartis les tâches », « fais travailler les autres comptes / l'autre Claude », « lance une équipe », « en parallèle », « découpe ça en tâches », « utilise tous mes comptes » — ou quand il confie un gros chantier fait de plusieurs morceaux indépendants alors que plusieurs comptes sont disponibles.
---

# Répartir une demande en tâches (équipe FLOW)

Tu es le **planificateur**. Tu ne fais pas le travail toi-même : tu étudies le projet, tu découpes
la demande en tâches qui peuvent avancer en même temps, et tu déposes ce plan dans la fenêtre
Équipe de FLOW. Là, l'utilisateur vérifie le plan et le lance ; FLOW ouvre alors un Claude par
tâche, répartis sur les comptes connectés, chacun dans sa copie du dépôt (git worktree, branche à
lui), puis fusionne, teste et attend la validation de l'utilisateur avant de toucher à sa branche.

Pendant le travail, FLOW synchronise l'équipe : un tableau partagé dit qui fait quoi, chaque ouvrier
annonce aux autres les décisions qui les concernent, et chaque tâche finie est **relue par un Claude
d'un autre compte** (relecture croisée) qui renvoie ses corrections à l'ouvrier avant la fusion.

Toi, tu ne peux pas écrire aux autres Claude ni piloter leurs panneaux : le plan est ton seul
canal. Tout ce qu'un ouvrier doit savoir au départ doit donc s'y trouver.

## 1. Toujours en équipe

Avec plusieurs comptes connectés, **toute demande de travail passe par l'équipe**, même petite : tous
les Claude travaillent ensemble, de façon autonome. Seules les questions, explications et échanges de
conversation se traitent seul.

- **La demande se découpe par morceaux** (fonctionnalités séparées, plusieurs modules, plusieurs
  fichiers) : une tâche par morceau.
- **Elle est petite ou indivisible par fichiers** : découpe par **rôles** qui avancent en parallèle sur
  la même chose — un *réalisateur* (le code), un *testeur* (écrit les tests à partir de la
  spécification du brief, sans voir le code : il fixe ce qui est attendu), de la *documentation et des
  exemples* ; puis, en dépendance, une tâche d'*intégration et de contre-vérification* qui fait passer
  l'ensemble et cherche les cas limites. Le brief fixe d'abord l'interface (noms, signatures, formats),
  pour que chacun avance sans attendre les autres.

Ne crée jamais une tâche vide pour occuper un compte : chaque rôle doit produire quelque chose de
vérifiable. Les ouvriers peuvent s'écrire directement (une ligne « @B : … » dans leurs annonces) et
n'appellent l'utilisateur qu'en dernier recours.

Vérifie aussi le terrain :
- le projet est un dépôt Git avec au moins un commit (`git status`). Sinon, propose de
  l'initialiser — les copies de travail en ont besoin ;
- s'il y a des modifications non commitées, préviens : les ouvriers partent du dernier commit et ne
  les verront pas. Demande s'il faut les commiter d'abord.

## 2. Étudier le projet

Lis `CLAUDE.md`, le README et `.flow\config.json` s'il existe (vérifications et conventions du
projet), puis explore en lecture seule juste assez pour savoir **quels fichiers** chaque morceau
va créer ou modifier. C'est ce qui décide si deux tâches peuvent tourner en même temps.

## 3. Découper

Règles, et leur raison :

- **Un fichier appartient à une seule tâche.** Les ouvriers ne se voient pas travailler : deux
  tâches sur le même fichier produisent un conflit à la fusion. Si c'est inévitable, la seconde
  dépend de la première (`depends`) : elle partira de son résultat.
- **Chaque tâche est autonome.** Son objectif doit se comprendre sans la conversation en cours :
  l'ouvrier n'a que le plan. Écris ce qu'il faut faire, où, et ce qui est hors de son périmètre.
- **Chaque tâche est vérifiable.** `done` dit comment savoir que c'est fini (tests qui passent,
  commande qui renvoie tel résultat, page qui affiche telle chose).
- **Préfère l'indépendance.** N'utilise `depends` que par nécessité : une chaîne de dépendances
  n'est plus du travail en parallèle.
- **Autant de tâches que de comptes, quand c'est possible.** Chaque compte connecté doit avoir de quoi travailler : avec 2 comptes, vise au
  moins 2 tâches indépendantes dès que la demande s'y prête (une seule tâche n'est acceptable que si la demande est indivisible ; l'autre
  compte la relira alors). Deux à quatre tâches en général (huit au plus). Des tâches de taille comparable se
  terminent ensemble ; une tâche minuscule peut se fondre dans sa voisine.
- **Pense au raccord.** Le relecteur de chaque tâche vérifie qu'elle s'emboîte avec les autres en
  s'appuyant sur le brief : plus les points de contact y sont précis, plus la relecture est utile.
- **Le brief porte ce qui est commun** : l'objectif global, les conventions du projet, et surtout
  les décisions que tous doivent respecter pour que les morceaux s'emboîtent — noms de fonctions
  ou de routes partagés, formats de données, emplacement des nouveaux fichiers. Si la tâche B
  appelle ce que la tâche A crée, le nom et la forme exacte doivent être fixés dans le brief.
- **Un modèle par tâche** : `haiku` pour le simple et mécanique (renommage, documentation,
  configuration), `sonnet` pour le travail courant bien défini, `opus` seulement pour le délicat
  (architecture, débogage difficile, changement transversal). `why` le justifie en quelques mots.

N'attribue pas les comptes toi-même : FLOW les répartit selon les comptes connectés et leurs
limites du moment, et l'utilisateur peut les changer dans l'écran du plan.

## 4. Écrire le plan

Écris le plan dans un fichier JSON hors du dépôt (par exemple dans le dossier temporaire), sous
cette forme exacte :

```json
{
  "request": "la demande de l'utilisateur, telle qu'il l'a formulée",
  "summary": "la demande résumée en une phrase",
  "commitTitle": "titre du commit final, dans le style de commit du projet",
  "brief": "contexte commun en Markdown : objectif, conventions, décisions partagées",
  "tasks": [
    {
      "id": "A",
      "title": "titre court",
      "goal": "ce qu'il faut faire, précisément, et ce qui est hors périmètre",
      "files": ["chemins/relatifs/des/fichiers.créés-ou-modifiés"],
      "depends": [],
      "done": "critères de fin vérifiables",
      "model": "sonnet",
      "why": "pourquoi ce modèle"
    }
  ]
}
```

## 5. Montrer, puis déposer

Présente d'abord le découpage à l'utilisateur en quelques lignes — une ligne par tâche (ce qu'elle
fait, ses fichiers, ce dont elle dépend) — et les décisions communes du brief. S'il a demandé de
foncer, enchaîne ; sinon attends son accord ou ses corrections.

Puis dépose le plan (depuis le dossier du projet) :

```
pwsh -NoProfile -File "{{FLOW_ROOT}}\tools\flow-plan.ps1" -Plan "<chemin du plan.json>"
```

Le script vérifie le plan (tâches complètes, dépendances cohérentes, fichiers partagés), crée
l'équipe « en attente » et ouvre la fenêtre Équipe quand on est dans une session FLOW. Lis sa
sortie : une ligne `ERREUR` se corrige dans le plan puis se relance ; une ligne `ATTENTION` se
transmet à l'utilisateur (ou se corrige si c'est un fichier partagé entre deux tâches).

## 6. Passer la main

Dis à l'utilisateur ce qui l'attend, simplement :

- la fenêtre Équipe est ouverte (fenêtre « dispatch » ; sinon `Ctrl+B` puis `T`). Si elle affiche
  l'écran de demande, `F6` montre les plans en attente ;
- il choisit le plan, vérifie comptes et modèles (`Tab` change le compte d'une tâche, `A` refait
  la répartition, `C` connecte un compte manquant), puis `Entrée` lance l'équipe ;
- pendant le travail, chaque tâche finie est relue par un Claude d'un autre compte ; les corrections
  demandées repartent chez l'ouvrier (`V` dans la fenêtre Équipe active ou coupe cette relecture) ;
- à la fin, FLOW fusionne et teste, et rien n'arrive dans sa branche sans sa validation.

Ensuite, **ne commence pas les tâches toi-même** : elles seraient faites deux fois, et tes
modifications dans le dossier principal gêneraient la fusion. Reste disponible pour répondre aux
questions ou ajuster le plan (un nouveau dépôt de plan crée une nouvelle équipe ; l'ancienne
s'abandonne depuis son écran avec `Échap`).

## Si FLOW n'est pas disponible

Si le script est introuvable ou échoue pour une raison d'environnement, ne simule pas une équipe :
donne le plan à l'utilisateur sous forme lisible et propose soit de le réaliser toi-même tâche par
tâche, soit d'ouvrir FLOW (profil Équipe) pour le lancer.
