# claude-usage-widget

Petit widget flottant pour macOS qui affiche la consommation réelle de ton
forfait Claude Code : fenêtre de session, quota hebdomadaire, et quota par
modèle. Swift/AppKit, un seul fichier, aucune dépendance.

Un clic bascule entre le panneau détaillé et une bulle compacte. Clic droit
pour le menu (rafraîchir, réduire, replacer, lancer au démarrage, quitter).

> **Non officiel.** Ce projet n'est ni affilié à Anthropic ni approuvé par
> Anthropic. Il s'appuie sur `/api/oauth/usage`, un endpoint **non documenté**
> qui peut changer de forme, être restreint ou disparaître sans préavis — le
> format de réponse a déjà changé une fois (voir le repli codé dans `parse`).
> À utiliser en connaissance de cause.

## Installation

Nécessite macOS et les outils en ligne de commande Xcode (`xcode-select --install`),
ainsi que [Claude Code](https://claude.com/claude-code) déjà connecté sur la machine.

```sh
git clone https://github.com/ChloeCru/claude-usage-widget.git
cd claude-usage-widget
./install/install.sh
```

Le script compile, installe dans `~/Library/Application Support/ClaudeUsageWidget/`
et enregistre un LaunchAgent pour le lancer à l'ouverture de session. Le chemin
du `.plist` est construit à partir de `$HOME`, il n'y a rien à éditer à la main.

Désinstaller : `./install/uninstall.sh`

## Comment il lit ton quota

Le token OAuth est **relu dans le trousseau à chaque appel** (entrée
`Claude Code-credentials`, que Claude Code garde rafraîchie) :

```sh
security find-generic-password -s "Claude Code-credentials" -w
```

**Aucun secret n'est stocké dans ce dépôt, dans le binaire, ni dans les logs.**
Le token n'est jamais affiché ni journalisé. Les appels vont sur
`/api/oauth/usage` et `/api/oauth/profile` avec l'en-tête
`anthropic-beta: oauth-2025-04-20`.

La première fois, macOS peut demander l'autorisation d'accéder au trousseau.

## Fréquence d'interrogation

Le widget interroge l'API **toutes les 5 minutes**. Ne descends pas plus bas :
une version antérieure interrogeait toutes les 60 s (~1 440 appels/jour) et
finissait par se faire répondre `HTTP 429`.

En cas de 429, le widget applique un backoff — il respecte `Retry-After` s'il
est fourni, sinon attend 10, 20 puis 40 minutes, plafonné à 1 h — et affiche
**« bridé »** en orange. « Hors ligne » en rouge signale un vrai échec réseau.
Le menu « Rafraîchir » force un appel malgré le backoff.

## Dépannage

Le journal horodaté est dans `/tmp/claude-usage-widget.err.log`. Il ne contient
que des codes HTTP et des messages d'état, jamais de token.

| Affichage | Cause |
|---|---|
| `bridé` | HTTP 429, trop d'appels. Le widget temporise seul. |
| `hors ligne` | Échec réseau, token absent du trousseau, ou réponse inexploitable. |
| `Chargement…` | Premier appel en cours. |

## Compiler à la main

```sh
swiftc -O main.swift -o claude-usage-widget
```

## Licence

MIT — voir [LICENSE](LICENSE).
