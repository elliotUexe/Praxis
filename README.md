# Praxis

App macOS native (SwiftUI + SwiftData) qui enregistre et transcrit des cours en direct, en extrait des tâches et un résumé via un LLM (local ou payant), et centralise ces tâches dans un gestionnaire dédié avec découpage en sous-tâches, minuteur de concentration et export vers le vault Obsidian. Anciennement AuTex (prototype Python antérieur, hors de ce dépôt).

Statut : alpha (`0.1.0-alpha.1`), usage personnel.

## Fonctionnalités

- **Enregistrement + transcription en direct** (WhisperKit, deux passes : rapide + raffinement) et **import** d'un fichier audio existant.
- **Résumé roulant + extraction de tâches** pendant l'enregistrement, via un provider payant (Gemini ou Claude, clé dans Réglages) ou le **modèle local Qwen2.5-7B-Instruct-4bit** (aucun coût récurrent). Repli automatique sur le modèle local si aucune clé payante valide n'est configurée.
- **Case à cocher "IA locale (Qwen)"** (section Enregistrement) : décochée, le modèle est déchargé de la mémoire immédiatement et aucune fonction IA locale ne tourne (résumé, extraction, Q&A, sous-tâches) — la transcription continue normalement.
- **Gestionnaire de tâches** (5 types : rendu, révision de fond, révision DS, blocage, anticipation), CRUD complet, import de texte collé, export Markdown vers un fichier du vault.
- **Sous-tâches** : ajout manuel (durée éditable, 30 min par défaut) ou proposées par le LLM local ("Découper avec l'IA"), toujours revues avant validation (jamais écrites directement en base).
- **Minuteur de concentration** par sous-tâche, avec visuel d'arbre qui pousse (dessiné nativement, pas d'asset tiers).
- **Bouton "Ouvrir le dossier du cours"** depuis une tâche, pour sauter directement au dossier vault correspondant.
- **Ingestion externe** générique (fichiers déposés dans un dossier de staging) avec dédoublonnage.
- **Vérification de mise à jour** au lancement (GitHub Releases) — voir [Publier une release](#publier-une-release).

## Prérequis

- Xcode récent avec le **Metal Toolchain** installé (`xcodebuild -downloadComponent MetalToolchain` si besoin — nécessaire pour compiler les shaders GPU de MLX).
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Mise en route

```sh
xcodegen generate
open Praxis.xcodeproj
```

Le fichier `Praxis.xcodeproj` est généré depuis `project.yml` et n'est **pas** versionné — le régénérer après chaque `git pull` qui touche `project.yml`, après un clone, ou après avoir ajouté un nouveau fichier source.

**Première compilation uniquement** : Xcode va demander de faire confiance au(x) plugin(s) de build de `mlx-swift` (popup "Trust & Enable"). Il faut le faire depuis Xcode.app directement (Cmd+B), pas en ligne de commande — c'est une confirmation de sécurité légitime, à ne jamais contourner.

Le modèle LLM local (Qwen2.5-7B-Instruct-4bit, ~4 Go) se télécharge à la première utilisation réelle (pas à la compilation), dans `~/.cache/huggingface/hub/`.

## Structure

```
Praxis/
  App/           coquille de l'app, sections (Enregistrement, Tâches, Résumés), Réglages,
                 thème, icône barre de menu, vérification de mise à jour
  Audio/         capture micro
  Transcription/ WhisperKit (live + import), raffinement
  AI/            providers résumé (Gemini, Claude) + coordinateur LLM local (Qwen)
  Tasks/         modèle SwiftData (tâches, sous-tâches, sessions de concentration),
                 vues CRUD, export Markdown, scan des imports en attente
  Storage/       chemins du vault, cache de planning de cours
  Resources/     Info.plist, icônes
PraxisSmokeTest/  outil CLI : test rapide de transcription WhisperKit sur un .wav
PraxisLLMBench/   outil CLI : mesure le temps de réponse du modèle local sur un prompt
                  donné, sans passer par l'app — utile pour ajuster prompts/paramètres
                  de génération en quelques secondes au lieu de relancer toute l'app
project.yml       source de vérité du projet Xcode (xcodegen)
```

### Stockage

- Base de données des tâches (SwiftData) : `~/Library/Application Support/Praxis/PraxisTasks.store` — volontairement hors du vault Obsidian.
- Vault Obsidian : `~/Documents/Obsidian` (`VaultPaths.root`) — export manuel des tâches, dossiers de cours, cache de planning.
- Clés API (Gemini/Claude) : Trousseau macOS (Keychain), jamais en clair sur disque.

## Outils de diagnostic

```sh
# Transcription
.build_or_derived_data/PraxisSmokeTest chemin/vers/fichier.wav

# Latence/qualité du LLM local, indépendamment de l'app GUI
.build_or_derived_data/PraxisLLMBench [maxTokens] "mon prompt de test"
```

Les binaires sont dans `~/Library/Developer/Xcode/DerivedData/Praxis-*/Build/Products/Debug/` après un build de leur scheme respectif (`xcodebuild -scheme PraxisSmokeTest build` / `-scheme PraxisLLMBench build`).

## Publier une release

Praxis n'a pas de compte Apple Developer payant : les builds sont signés en ad-hoc ("Sign to Run Locally"), non notarisés. Au premier lancement d'une nouvelle version téléchargée, macOS/Gatekeeper affichera un avertissement — clic droit → Ouvrir (une seule fois) au lieu d'un double-clic normal.

1. Mettre à jour `MARKETING_VERSION` dans `project.yml` si besoin.
2. `git tag v0.2.0 && git push origin v0.2.0` (le nom du tag doit commencer par `v`).
3. Le workflow `.github/workflows/release.yml` build l'app en Release, zippe le `.app`, et publie une Release GitHub avec le zip en asset.
4. Au prochain lancement, `UpdateCheckCoordinator` interroge l'API GitHub Releases et affiche un badge dans la barre d'outils + un lien de téléchargement dans Réglages si une version plus récente existe. Pas d'installation automatique silencieuse (nécessiterait signature/notarisation) — juste une notification avec lien vers la page de release.

## Licence

Apache 2.0 — voir `LICENSE`.
