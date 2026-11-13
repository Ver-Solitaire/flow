# Choix par défaut selon le type de projet

Ce sont des points de départ raisonnables, pas des obligations : une contrainte de l'utilisateur
(langage imposé, outil déjà installé, hébergement existant) passe toujours avant. Vérifie les
commandes dans la documentation officielle si un générateur a changé.

## Sommaire
- Site vitrine ou page statique
- Application web (interface + données)
- API / service
- Outil en ligne de commande
- Script ou automatisation
- Bibliothèque
- Application de bureau
- Application mobile
- Jeu
- Analyse de données / notebook
- Bot (Discord, Telegram, Slack…)
- Extension de navigateur
- Projet sans code

## Site vitrine ou page statique
- **Défaut** : HTML + CSS (+ un peu de JavaScript) sans outil de build. Si plusieurs pages
  partagent une mise en page ou du contenu en Markdown : Astro.
- **Socle** : `index.html`, `styles.css`, dossier `assets/`, lancement par un petit serveur local
  (`npx serve` ou `python -m http.server`).
- **Vérifier** : la page s'affiche, les liens internes marchent, rendu correct en largeur téléphone.

## Application web (interface + données)
- **Défaut** : TypeScript. Interface seule : Vite + React. Avec pages serveur, comptes ou base de
  données : Next.js. Petite application pilotée par le serveur : Python + FastAPI/Flask avec des
  gabarits HTML.
- **Données** : SQLite tant qu'il y a un seul serveur ; Postgres si plusieurs instances ou
  beaucoup d'écritures simultanées.
- **Socle** : générateur officiel, une page réelle, un test (Vitest ; Playwright pour un parcours
  complet), ESLint + Prettier (ou Biome), `.env.example`.
- **Vérifier** : serveur de développement lancé et page chargée, build de production qui passe.

## API / service
- **Défaut** : Python + FastAPI (documentation interactive incluse) ou TypeScript + Hono/Fastify.
  Go si la performance ou un binaire unique compte.
- **Socle** : une route de santé (`/health`), une vraie route, validation des entrées, tests des
  routes, configuration par variables d'environnement, erreurs renvoyées dans un format constant.
- **Vérifier** : serveur lancé, la route répond à un appel réel (`curl`), tests verts.

## Outil en ligne de commande
- **Défaut** : Python (argparse ou Typer) pour un outil personnel ; Go ou Rust (clap) si l'outil
  doit être distribué en un seul fichier ; Node si l'écosystème visé est JavaScript.
- **Socle** : `--help` soigné, codes de sortie corrects (0 = réussi), messages d'erreur sur la
  sortie d'erreur, un test par commande.
- **Vérifier** : exécuter l'outil sur un cas réel et sur une entrée invalide.

## Script ou automatisation
- **Défaut** : Python ; PowerShell quand il s'agit de piloter Windows lui-même.
- **Socle** : un fichier principal, les réglages en haut ou dans un fichier de configuration,
  un mode « à blanc » (`--dry-run`) dès que le script supprime, envoie ou modifie quelque chose,
  un journal lisible de ce qui a été fait.
- **Vérifier** : une exécution à blanc, puis réelle sur un petit échantillon.

## Bibliothèque
- **Défaut** : le langage de ses futurs utilisateurs. Python : `uv init --lib`. TypeScript :
  `tsup` ou `tsc` avec les types exportés. Rust : `cargo new --lib`.
- **Socle** : une interface publique petite et documentée, des exemples dans le README qui sont
  aussi des tests, numérotation de version sémantique, fichier de licence (demander laquelle).
- **Vérifier** : installer la bibliothèque dans un dossier vierge et exécuter l'exemple du README.

## Application de bureau
- **Défaut** : Tauri (léger) ou Electron (plus répandu) si l'interface est web ; .NET (WPF ou
  WinForms) pour un outil Windows uniquement ; Python + Qt (PySide) pour un outil interne.
- **Socle** : fenêtre principale, une action réelle, icône, commande de build d'un exécutable.
- **Vérifier** : l'application s'ouvre, l'action marche, l'exécutable se construit.

## Application mobile
- **Défaut** : React Native avec Expo (une seule base de code, test immédiat sur son téléphone) ;
  Flutter en alternative ; natif (Swift, Kotlin) seulement si une fonction du téléphone l'exige.
- **Avant de commencer** : une application web installable (PWA) suffirait-elle ? C'est souvent
  beaucoup plus simple à publier et à maintenir.
- **Vérifier** : démarrage dans le simulateur ou sur Expo Go ; dire ce qui n'a pas pu être testé
  sans appareil réel.

## Jeu
- **Défaut** : navigateur — Phaser (2D) ou Three.js (3D), aucun outil à installer pour y jouer ;
  Godot pour un jeu plus ambitieux ; Pygame pour apprendre.
- **Socle** : la boucle de jeu, une scène jouable (même minuscule), les réglages du jeu regroupés
  dans un seul fichier, les ressources dans `assets/` avec leur provenance et leur licence.
- **Vérifier** : lancer et jouer réellement une partie.
- Jeu original uniquement : ne pas reproduire les personnages, les niveaux ou l'habillage d'un jeu
  existant.

## Analyse de données / notebook
- **Défaut** : Python avec `uv`, pandas (ou polars), Jupyter. Le code réutilisable va dans un
  dossier `src/`, les notebooks ne font que l'appeler.
- **Socle** : `data/raw/` (jamais modifié) et `data/processed/`, un script qui régénère tous les
  résultats depuis les données brutes, les gros fichiers de données hors de Git.
- **Vérifier** : tout relancer depuis zéro et retrouver les mêmes chiffres.

## Bot (Discord, Telegram, Slack…)
- **Défaut** : la bibliothèque officielle ou la plus utilisée de la plateforme (discord.js ou
  discord.py, grammY ou python-telegram-bot, Bolt pour Slack).
- **Socle** : jeton dans `.env` (jamais dans le code), une commande réelle, gestion des erreurs
  qui n'arrête pas le bot, instructions de création du bot côté plateforme dans le README.
- **Vérifier** : la logique se teste sans la plateforme ; le branchement réel demande le jeton de
  l'utilisateur — le lui dire au lieu de supposer que ça marche.

## Extension de navigateur
- **Défaut** : Manifest V3, TypeScript, WXT ou Vite avec le plugin d'extension.
- **Socle** : permissions minimales (chacune justifiée dans le README), une action réelle,
  instructions de chargement en mode développeur.

## Projet sans code
Documentation, livre, cours, recherche, dossier d'entreprise.
- **Défaut** : Markdown dans Git ; un générateur (MkDocs, Quarto, Pandoc) seulement s'il faut
  publier en site ou en PDF.
- **Socle** : arborescence par sujet, convention de nommage (`01-introduction.md`…), README qui
  dit où va quoi et comment produire le document final, un dossier `sources/` pour les références.
- **Vérifier** : la commande de génération produit bien le document.
