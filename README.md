# claude-codex-skills-sync

Synchronise tes skills entre **Claude Code CLI** (`~/.claude/skills/`), **Codex** (`~/.codex/skills/`) et **Cursor** (`~/.cursor/skills/`).
Toutes directions au choix, dry-run par défaut, backups groupés par session, restauration interactive.

```
═══ Skills Sync Tool ═══
(DRY-RUN — apply proposé à la fin de chaque opération, ou --apply au lancement)

  1) Synchroniser entre deux cibles
  2) Lister les backups
  3) Restaurer un backup
  4) Quitter

  Cibles : Claude (~/.claude/skills), Codex (~/.codex/skills), Cursor (~/.cursor/skills)
```

Après `1)`, le script demande la **source** puis la **destination** parmi les 3 cibles — soit 6 directions possibles (Claude↔Codex, Claude↔Cursor, Codex↔Cursor).

---

## Pourquoi

Si tu utilises plusieurs assistants IA (Claude Code, Codex, Cursor), tu écris probablement tes skills d'un côté et tu fais du copier-coller manuel de l'autre. Les trois outils partagent le **même format** : YAML frontmatter `name` + `description` + contenu Markdown. Mais aucun outil natif n'existe pour les garder alignés.

Ce script résout ce problème en une commande, avec des garde-fous (dry-run, backups, restore).

## Installation

```bash
git clone https://github.com/sanztheo/claude-codex-skills-sync.git
cd claude-codex-skills-sync
chmod +x sync-skills.sh
./sync-skills.sh
```

Ou en one-liner (curl direct) :

```bash
curl -fsSL https://raw.githubusercontent.com/sanztheo/claude-codex-skills-sync/main/sync-skills.sh -o ~/sync-skills.sh
chmod +x ~/sync-skills.sh
~/sync-skills.sh
```

**Dépendances** : bash, `diff`, `cp`, `find`. Aucune installation supplémentaire requise (tout est dispo sur macOS et Linux par défaut).

## Usage

### Mode interactif (recommandé)

```bash
./sync-skills.sh
```

Tu choisis une direction. Le script affiche un plan (combien de skills sont nouveaux, différents, identiques), te demande si tu veux le détail, puis te propose d'appliquer.

### Mode direct (skip le dry-run)

```bash
./sync-skills.sh --apply
```

### Aide

```bash
./sync-skills.sh --help
```

## Guide complet

### Comportement par skill

Pour chaque skill du répertoire source, le script compare avec la destination :

| Cas | Détection | Action |
|---|---|---|
| **NEW** | Skill absent côté destination | Copié tel quel |
| **DIFF** | Présent mais contenu différent (`diff -rq`) | Backup de la version destination, puis remplacement par la source |
| **SAME** | Identique octet pour octet | Ignoré (skip) |

Les dossiers commençant par `_` (ex. `_archived`) ou `.` sont exclus automatiquement.

### Backups

Chaque session de sync qui écrase au moins un skill crée un dossier de backup horodaté :

```
~/.skills-sync-backups/
└── 2026-05-28_14-32-15_claude-to-codex/
    ├── .session_info        (src, dst, label, timestamp)
    ├── brainstorming/       (version Codex avant écrasement)
    └── writing-plans/       (version Codex avant écrasement)
```

Les backups sont des copies brutes des dossiers de skills (pas d'archive), donc inspectables et restaurables sans outil tiers.

### Restauration

Menu option **4** :

1. Le script liste les sessions de backup disponibles.
2. Tu choisis une session (par numéro).
3. Tu choisis quoi restaurer : `all` (tous les skills de la session), un numéro, ou un nom de skill.
4. Avant de restaurer, le script backupe l'état actuel dans `..._pre-restore/`. Tu peux donc annuler une restauration en restaurant depuis ce pre-restore.

### Mode dry-run

Par défaut, le script est en dry-run : il calcule le plan, affiche les changements, mais ne touche pas au disque tant que tu n'as pas explicitement confirmé.

Deux façons d'appliquer :
- **Mid-session** : tu lances `./sync-skills.sh`, vois le plan, et réponds `y` à la question *"Voulez-vous APPLIQUER ces changements maintenant ?"*
- **Direct** : `./sync-skills.sh --apply` saute le dry-run et te demande directement de confirmer.

### Configuration avancée (env vars)

Tu peux pointer le script ailleurs que les chemins par défaut, utile pour tester ou pour des installations non standard :

```bash
SKILLS_SYNC_CLAUDE_DIR=/chemin/custom/claude/skills \
SKILLS_SYNC_CODEX_DIR=/chemin/custom/codex/skills \
SKILLS_SYNC_CURSOR_DIR=/chemin/custom/cursor/skills \
SKILLS_SYNC_BACKUP_ROOT=/chemin/backups \
  ./sync-skills.sh
```

## Tests

Un harness d'intégration est fourni. Il crée un faux setup dans `/tmp` (avec les 3 cibles Claude, Codex, Cursor), exécute toutes les opérations (sync, restore), vérifie 14 assertions et nettoie tout :

```bash
./test.sh
```

Couverture :
- Cas NEW, DIFF, SAME pour Claude→Codex
- Cas NEW pour Claude→Cursor (3e cible)
- Exclusion de `_archived`
- Copie récursive des sous-dossiers (`assets/`)
- Préservation du frontmatter YAML
- Le sync Claude→Codex ne touche pas aux skills Codex-only
- Le sync Claude→Cursor ne touche pas aux skills Codex (isolation des cibles)
- Création du dossier de backup
- Restauration complète
- Création du `_pre-restore` (sécurité avant restore)

Sortie attendue : `✓ TOUS LES TESTS PASSENT (0 échec)`.

## Format des skills

Les trois écosystèmes utilisent le même format minimal :

```markdown
---
name: mon-skill
description: "Description courte qui détermine quand le skill est déclenché."
---

# Mon Skill

Contenu Markdown libre, sections, exemples, etc.
```

Comme le format est identique, le script n'a pas besoin de transformer le contenu : il copie atomiquement les dossiers entiers (`cp -a`). Cela préserve aussi les ressources embarquées (assets, sous-skills, références, scripts).

## FAQ

**Le script va-t-il toucher à mes skills si je clique au mauvais endroit ?**
Non. Le dry-run est le mode par défaut et chaque action destructive demande une confirmation `y/N` (défaut = non). Les backups sont créés *avant* tout écrasement.

**Que se passe-t-il si un skill a un sous-dossier ou des fichiers en plus du SKILL.md ?**
Tout est copié récursivement (`cp -a`). La comparaison `diff -rq` détecte aussi les changements dans les sous-dossiers.

**Comment supprimer un skill côté destination ?**
Le script ne supprime jamais. Tu peux supprimer manuellement, ou faire un sync inverse depuis une source qui n'a plus le skill (mais cela ne supprime pas non plus — le script ne fait que copier/écraser).

**Comment annuler un sync raté ?**
Menu option **3** (Restaurer un backup), choisis la session, tape `all`, confirme. Le pre-restore est créé en sécurité.

**Mes descriptions de skills sont différentes entre Claude, Codex et Cursor, c'est normal ?**
Oui, c'est un choix valide (chaque écosystème peut avoir sa propre formulation de trigger). Le script considère cela comme un cas **DIFF** : il backupe puis écrase la version destination. Si tu veux préserver les divergences volontaires, fais un sync sélectif (tu peux toujours restaurer après).

**Et `~/.cursor/rules/` ? Le script le synchronise ?**
Non. `~/.cursor/rules/*.md` est un format différent (Markdown plat avec frontmatter Cursor — `description`, `alwaysApply`, `globs`) qui sert de configuration projet, pas de skills réutilisables. Le script ne touche qu'à `~/.cursor/skills/`, qui partage le format Claude/Codex.

**Et `~/.cursor/skills-cursor/` ?**
Non plus. Ce dossier contient des skills spécifiques à l'éditeur Cursor (par ex. `canvas`, `migrate-to-skills`) qui n'ont pas leur équivalent côté Claude ou Codex. Pour les inclure quand même, override `SKILLS_SYNC_CURSOR_DIR=~/.cursor/skills-cursor`.

**Codex répond bizarrement après un sync, est-ce un bug du script ?**
Probablement pas. Si tu as un `~/.codex/AGENTS.md` avec une règle globale type "planning gate" (workflows `ralph`, `autopilot`...), elle peut intercepter ta requête avant que le skill ne s'exécute. Le sync filesystem reste correct — vérifie avec `diff -rq` que le contenu est bien là.

## License

MIT
