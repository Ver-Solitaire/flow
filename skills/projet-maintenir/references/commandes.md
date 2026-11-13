# Commandes de maintenance par écosystème

Repère l'écosystème grâce aux fichiers du projet, puis lis seulement sa section. Si le projet
définit ses propres commandes (scripts de `package.json`, `Makefile`, CI, `CLAUDE.md`), elles
passent avant celles-ci.

| Fichier présent | Section |
|---|---|
| `package.json` (+ `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lock`) | JavaScript / TypeScript |
| `pyproject.toml`, `requirements.txt`, `uv.lock`, `poetry.lock` | Python |
| `Cargo.toml` | Rust |
| `go.mod` | Go |
| `*.csproj`, `*.sln` | .NET |
| `composer.json` | PHP |
| `Gemfile` | Ruby |
| `pom.xml`, `build.gradle*` | Java / Kotlin |
| `Dockerfile`, `.github/workflows/` | Images et intégration continue |

## JavaScript / TypeScript
Utilise le gestionnaire du projet (celui du fichier de verrouillage), jamais un autre.

| Besoin | npm | pnpm | yarn | bun |
|---|---|---|---|---|
| Installer à l'identique | `npm ci` | `pnpm install --frozen-lockfile` | `yarn install --frozen-lockfile` | `bun install --frozen-lockfile` |
| Voir ce qui est en retard | `npm outdated` | `pnpm outdated` | `yarn outdated` | `bun outdated` |
| Mettre à jour (mineures) | `npm update` | `pnpm update` | `yarn upgrade` | `bun update` |
| Passer une majeure | `npm install paquet@latest` | `pnpm add paquet@latest` | `yarn add paquet@latest` | `bun add paquet@latest` |
| Audit de sécurité | `npm audit` | `pnpm audit` | `yarn audit` | `bun audit` |
| Dépendances inutilisées | `npx knip` ou `npx depcheck` | | | |

- Tests, lint, types, build : les scripts de `package.json` (`npm test`, `npm run lint`,
  `npm run typecheck`, `npm run build`).
- `npm audit fix` sans `--force` reste dans les versions compatibles ; `--force` installe des
  majeures : à éviter.
- Version de Node attendue : champ `engines` de `package.json`, fichier `.nvmrc` ou `.node-version`.

## Python
| Besoin | uv | poetry | pip |
|---|---|---|---|
| Installer | `uv sync` | `poetry install` | `pip install -r requirements.txt` (dans un environnement virtuel) |
| Voir ce qui est en retard | `uv pip list --outdated` | `poetry show --outdated` | `pip list --outdated` |
| Mettre à jour un paquet | `uv lock --upgrade-package paquet` puis `uv sync` | `poetry update paquet` | modifier `requirements.txt`, réinstaller |
| Tout mettre à jour | `uv lock --upgrade` puis `uv sync` | `poetry update` | — |
| Audit de sécurité | `uvx pip-audit` | `pip-audit` | `pip-audit` |

- Tests : `pytest -q` (préfixé par `uv run` ou `poetry run` selon le projet).
- Lint et format : `ruff check .` et `ruff format .` ; types : `mypy .` ou `pyright` si configurés.
- Travaille toujours dans l'environnement virtuel du projet (`.venv`), jamais dans le Python global.
- Version de Python attendue : `requires-python` dans `pyproject.toml` ou fichier `.python-version`.

## Rust
- En retard : `cargo outdated` (à installer : `cargo install cargo-outdated`) ; mise à jour
  compatible : `cargo update` ; majeure : modifier `Cargo.toml` ou `cargo add paquet@version`.
- Audit : `cargo audit` (`cargo install cargo-audit`).
- Vérifier : `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test`, `cargo build --release`.

## Go
- En retard : `go list -m -u all` ; mise à jour : `go get -u ./...` (ou un module : `go get
  module@latest`), puis `go mod tidy`.
- Audit : `govulncheck ./...` (`go install golang.org/x/vuln/cmd/govulncheck@latest`).
- Vérifier : `go vet ./...`, `go test ./...`, `go build ./...`.

## .NET
- En retard : `dotnet list package --outdated` ; failles : `dotnet list package --vulnerable`.
- Mettre à jour : `dotnet add package Nom` (dernière version) ou modifier le `.csproj`.
- Vérifier : `dotnet build`, `dotnet test`, `dotnet format --verify-no-changes`.

## PHP
- En retard : `composer outdated` ; mise à jour : `composer update paquet` ; audit : `composer audit`.
- Vérifier : `vendor/bin/phpunit`, et l'analyseur du projet (`phpstan`, `psalm`) s'il est configuré.

## Ruby
- En retard : `bundle outdated` ; mise à jour : `bundle update paquet` ; audit : `bundle audit`
  (`gem install bundler-audit`).
- Vérifier : `bundle exec rspec` ou `bundle exec rake test`, `bundle exec rubocop`.

## Java / Kotlin
- Maven : `mvn versions:display-dependency-updates`, tests `mvn -q test`.
- Gradle : plugin `com.github.ben-manes.versions` (`./gradlew dependencyUpdates`), tests
  `./gradlew test` (sous Windows : `.\gradlew.bat`).
- Audit : OWASP Dependency-Check (`mvn org.owasp:dependency-check-maven:check`).

## Images et intégration continue
- `Dockerfile` : images de base avec une version précise (pas `latest`) ; les mettre à jour comme
  une dépendance, puis reconstruire l'image et lancer le conteneur pour vérifier.
- GitHub Actions : mettre à jour les versions des actions (`actions/checkout@v…`) ; garder les
  versions de langage de la CI alignées avec celles du projet.
- Après une modification de la CI, le seul vrai test est une exécution : le dire à l'utilisateur
  s'il faut pousser pour la déclencher.

## Git : repères pour la maintenance
- Dernière version publiée : `git describe --tags --abbrev=0`
- Changements depuis : `git log <tag>..HEAD --oneline`
- Annuler un commit de maintenance déjà fait : `git revert <commit>` (crée un commit inverse, ne
  réécrit pas l'historique).
- Branches locales déjà fusionnées : `git branch --merged` — à montrer avant de supprimer.
