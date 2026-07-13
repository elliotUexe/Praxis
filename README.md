# Praxis

Système d'enregistrement, de transcription et de génération de todoliste et de résumés — app macOS native (SwiftUI), avec extraction assistée par LLM local. Anciennement AuTex (prototype Python antérieur, hors de ce dépôt).

## Prérequis

- Xcode récent avec le **Metal Toolchain** installé (`xcodebuild -downloadComponent MetalToolchain` si besoin — nécessaire pour compiler les shaders GPU de MLX).
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Mise en route

```sh
xcodegen generate
open Praxis.xcodeproj
```

Le fichier `Praxis.xcodeproj` est généré depuis `project.yml` et n'est **pas** versionné — le régénérer après chaque `git pull` qui touche `project.yml` ou après un clone.

**Première compilation uniquement** : Xcode va demander de faire confiance au plugin de build `CudaBuild` du package `mlx-swift` (popup "Trust & Enable"). Il faut le faire depuis Xcode.app directement (Cmd+B), pas en ligne de commande — c'est une confirmation de sécurité légitime, à ne jamais contourner.

Le modèle LLM local (Qwen2.5-7B-Instruct-4bit, ~4-5 Go) se télécharge à la première utilisation réelle, pas à la compilation.

## Structure

- `Praxis/` — code source de l'app (App, AI, Audio, Storage, Transcription, Tasks, Resources).
- `PraxisSmokeTest/` — outil CLI de test rapide de la transcription WhisperKit.
- `project.yml` — source de vérité du projet Xcode (xcodegen).

## Licence

Apache 2.0 — voir `LICENSE`.
