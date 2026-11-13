---
name: projet-creer
description: Crée un nouveau projet de A à Z, quel que soit son type (site ou application web, API, outil en ligne de commande, bibliothèque, script d'automatisation, application mobile ou de bureau, jeu, analyse de données, bot, ou projet sans code comme une documentation ou un livre). À utiliser dès que l'utilisateur veut démarrer quelque chose de nouveau — « crée-moi un projet », « je veux faire une appli / un site / un outil qui… », « nouveau projet », « pars de zéro », « initialise le dossier », « mets en place la structure » — ou quand le dossier de travail est vide ou presque et qu'il décrit une idée à construire, même s'il ne prononce pas le mot « projet ».
---

# Créer un projet

Le but : partir d'une idée et arriver à un projet **qui tourne**, rangé proprement, que l'on peut
reprendre dans six mois (ou confier à un autre Claude) sans rien deviner. Un squelette vide ne vaut
rien ; un projet minimal qui démarre, se teste et s'explique vaut beaucoup.

## 1. Comprendre avant de construire

Regarde d'abord le dossier : s'il contient déjà un projet, ce skill n'est pas le bon — passe à
`projet-reprendre`. S'il contient quelques fichiers (notes, maquettes, données), lis-les : ce sont
des indices sur ce que l'utilisateur veut.

Puis assure-toi de connaître ces points. Déduis ce que tu peux de la demande et ne pose que les
questions dont la réponse change réellement ce que tu vas construire (trois ou quatre au plus, en
une seule fois, avec ta proposition par défaut pour chacune) :

- **À quoi ça sert, et pour qui ?** Une phrase. C'est elle qui ouvrira le README.
- **Où ça tourne ?** Navigateur, téléphone, PC de l'utilisateur, serveur, nulle part (bibliothèque)…
- **Quelle taille ?** Un essai du week-end, un outil personnel durable, un produit pour d'autres.
- **Des contraintes ?** Langage imposé, hébergement, budget, données sensibles, hors-ligne…
- **Qui va le maintenir ?** Si l'utilisateur ne programme pas, c'est toi (ou un autre Claude) :
  privilégie alors ce qui est simple à lancer et à diagnostiquer.

Si l'utilisateur dit « fais au mieux », choisis, annonce tes choix en deux lignes et avance.

## 2. Choisir les outils

Lis `references/types-de-projet.md` : il donne, pour chaque famille de projet, un choix par défaut
raisonnable et ce qu'il faut y mettre. Principes qui valent partout :

- **Banal et répandu plutôt que brillant.** Un outil très utilisé a de la documentation, des
  réponses à ses erreurs, et sera encore là dans trois ans. La nouveauté se paie en maintenance.
- **Le moins de pièces possible.** Pas de base de données tant qu'un fichier suffit, pas de
  framework tant que la bibliothèque standard suffit, pas de service payant sans l'avoir dit.
- **Ce que l'utilisateur a déjà.** Vérifie les outils installés (`node --version`, `python
  --version`, `git --version`…) avant d'en imposer un autre ; s'il manque quelque chose, dis-le et
  propose la commande d'installation au lieu d'échouer plus tard.
- **Versions réelles, pas de mémoire.** Laisse le gestionnaire de paquets choisir la dernière
  version stable (`npm install x`, `uv add x`, `cargo add x`…) au lieu d'écrire des numéros de
  version de tête : ils sont souvent périmés.

Explique le choix en langage courant (« Python parce que… », pas un comparatif) et passe à la suite.

## 3. Construire le socle

Crée, dans cet ordre, ce qui s'applique au type de projet :

1. **Le dépôt** : `git init` (branche `main`) si ce n'est pas déjà fait, et un `.gitignore` adapté
   aux outils choisis — avant le premier fichier généré, pour ne jamais commiter de dépendances ou
   de secrets.
2. **La structure** : les dossiers attendus par l'écosystème choisi, pas une arborescence inventée.
   Utilise le générateur officiel quand il existe (`npm create vite`, `cargo new`, `uv init`,
   `dotnet new`…) : il produit ce que la communauté attend.
3. **Un premier vrai morceau** : la plus petite version qui fait quelque chose d'utile de bout en
   bout (une page qui s'affiche avec une vraie donnée, une commande qui renvoie un vrai résultat).
   C'est ce qui prouve que les pièces s'emboîtent.
4. **Un test qui passe**, branché sur la commande de test standard de l'écosystème. Un seul test
   réel suffit : le but est que « lancer les tests » existe et marche dès le premier jour.
5. **Mise en forme et vérification automatiques** (formatage, lint, types) avec l'outil courant de
   l'écosystème et sa configuration par défaut.
6. **Les secrets à part** : un `.env.example` qui liste les variables sans leurs valeurs, `.env`
   dans le `.gitignore`. Ne mets jamais une vraie clé dans un fichier suivi par Git.
7. **Le README** (voir le modèle ci-dessous) et **`CLAUDE.md`** (voir plus bas).

Pour un projet sans code (documentation, livre, recherche, dossier administratif), le socle est :
une arborescence claire, une convention de nommage, un README qui dit où va quoi, et Git pour
l'historique.

### README : modèle

```markdown
# Nom du projet

Une phrase : ce que ça fait et pour qui.

## Démarrer
Prérequis (outils et versions), puis les commandes exactes pour installer et lancer.

## Utiliser
L'exemple le plus courant, copiable tel quel.

## Développer
Lancer les tests, vérifier le code, structure des dossiers en quelques lignes.

## État
Ce qui marche aujourd'hui, ce qui est prévu ensuite.
```

### CLAUDE.md : la mémoire du projet

Ce fichier est lu par chaque Claude qui ouvrira le projet (y compris les ouvriers d'une équipe
FLOW, chacun dans sa copie). Écris-y ce qu'un nouveau venu ne peut pas deviner en lisant le code :

- le but du projet en deux lignes ;
- les commandes : installer, lancer, tester, vérifier ;
- l'organisation des dossiers et où ajouter quoi ;
- les conventions choisies (langue des commentaires et des commits, style, nommage) ;
- les décisions prises et leur raison (« SQLite et pas Postgres parce que mono-utilisateur ») ;
- les pièges connus.

Court et exact vaut mieux que long : il sera relu à chaque session.

## 4. Vérifier pour de vrai

Avant d'annoncer que c'est prêt, exécute toi-même, depuis un état propre :

- l'installation des dépendances ;
- le lancement (et regarde le résultat : la page répond, la commande affiche ce qu'il faut) ;
- les tests et les vérifications.

Si quelque chose échoue, corrige-le maintenant. Un projet neuf qui ne démarre pas du premier coup
fait perdre confiance dans tout le reste. Si tu n'as pas pu vérifier un point (pas d'accès réseau,
outil absent), dis-le clairement plutôt que de le supposer.

## 5. Premier commit et passage de relais

Fais un premier commit (« Socle du projet : … ») une fois que tout tourne. Ne pousse rien vers
GitHub ou ailleurs et ne crée pas de dépôt distant sans que l'utilisateur le demande : publier
est sa décision.

Termine par un message court :

- ce qui a été créé, en une ou deux phrases ;
- **comment le lancer** (la commande exacte) ;
- ce qui a été vérifié, et ce qui ne l'a pas été ;
- les deux ou trois prochaines étapes que tu proposes.

## Garde-fous

- Reste dans le dossier du projet : n'installe rien globalement sur la machine et ne modifie pas
  de réglages système sans l'annoncer et obtenir l'accord.
- Pas de service payant, de compte à créer ou de déploiement sans accord explicite.
- Si la demande est grande, construis le socle et la première fonctionnalité, puis propose un plan
  pour la suite au lieu de tout générer d'un coup : ce qui n'a pas été vérifié s'accumule vite.
