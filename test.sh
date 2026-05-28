#!/usr/bin/env bash
# Test harness for sync-skills.sh — isolated, non-destructive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync-skills.sh"
[[ -x "$SYNC_SCRIPT" ]] || { echo "sync-skills.sh introuvable ou non exécutable à côté du test"; exit 2; }

TEST_ROOT="$(mktemp -d -t sync-skills-test-XXXXXX)"
CLAUDE="$TEST_ROOT/claude/skills"
CODEX="$TEST_ROOT/codex/skills"
CURSOR="$TEST_ROOT/cursor/skills"
BACKUPS="$TEST_ROOT/backups"
mkdir -p "$CLAUDE" "$CODEX" "$CURSOR"

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILS=$((FAILS+1)); }
FAILS=0

# ─── Cas 1 : SAME (skill identique des deux côtés) ───────────────────────────
mkdir -p "$CLAUDE/same-skill" "$CODEX/same-skill"
cat > "$CLAUDE/same-skill/SKILL.md" <<'EOF'
---
name: same-skill
description: "Skill identique des deux côtés."
---

# Same Skill
Contenu identique.
EOF
cp "$CLAUDE/same-skill/SKILL.md" "$CODEX/same-skill/SKILL.md"

# ─── Cas 2 : DIFF (description différente, contenu différent) ────────────────
mkdir -p "$CLAUDE/diff-skill" "$CODEX/diff-skill"
cat > "$CLAUDE/diff-skill/SKILL.md" <<'EOF'
---
name: diff-skill
description: "Version CLAUDE — la bonne."
---

# Diff Skill
Version Claude — récente.
EOF
cat > "$CODEX/diff-skill/SKILL.md" <<'EOF'
---
name: diff-skill
description: "Version CODEX — ancienne."
---

# Diff Skill
Version Codex — à écraser.
EOF

# ─── Cas 3 : NEW Claude-only ─────────────────────────────────────────────────
mkdir -p "$CLAUDE/claude-only"
cat > "$CLAUDE/claude-only/SKILL.md" <<'EOF'
---
name: claude-only
description: "Présent uniquement côté Claude."
---

# Claude Only
EOF
# Fichier supplémentaire (ressource dans le skill) pour tester copie récursive.
mkdir -p "$CLAUDE/claude-only/assets"
echo "ressource embarquée" > "$CLAUDE/claude-only/assets/notes.txt"

# ─── Cas 4 : Codex-only (doit rester intouché) ───────────────────────────────
mkdir -p "$CODEX/codex-only"
cat > "$CODEX/codex-only/SKILL.md" <<'EOF'
---
name: codex-only
description: "Présent uniquement côté Codex."
---

# Codex Only
EOF

# ─── Cas 5 : skill exclu (_archived) ─────────────────────────────────────────
mkdir -p "$CLAUDE/_archived"
echo "ne pas copier" > "$CLAUDE/_archived/SKILL.md"

# Snapshot avant
CLAUDE_DIFF_HASH_BEFORE="$(shasum "$CLAUDE/diff-skill/SKILL.md" | cut -d' ' -f1)"
CODEX_DIFF_HASH_BEFORE="$(shasum "$CODEX/diff-skill/SKILL.md" | cut -d' ' -f1)"

echo
echo "═══ Setup test ═══"
echo "  Claude skills : $(ls "$CLAUDE" | tr '\n' ' ')"
echo "  Codex  skills : $(ls "$CODEX"  | tr '\n' ' ')"
echo "  Cursor skills : $(ls "$CURSOR" | tr '\n' ' ')"

# Wrapper pour invoquer le script avec toutes les env vars en place.
run_sync() {
  SKILLS_SYNC_CLAUDE_DIR="$CLAUDE" \
  SKILLS_SYNC_CODEX_DIR="$CODEX" \
  SKILLS_SYNC_CURSOR_DIR="$CURSOR" \
  SKILLS_SYNC_BACKUP_ROOT="$BACKUPS" \
    "$SYNC_SCRIPT" "$@"
}

# Menu actuel (4 options) :
#   1) Synchroniser   2) Lister  3) Restaurer  4) Quitter
# Dans "Synchroniser", source/destination sont demandées séparément.
# Cibles : claude=1, codex=2, cursor=3.
# Quand on choisit source=claude, destination affiche {codex(1), cursor(2)}.

echo
echo "═══ Run 1 : DRY-RUN (claude→codex), refuse apply ═══"
run_sync <<EOF | sed 's/^/    /'
1
1
1
n
n
4
EOF

# Vérifie : rien n'a bougé
if [[ "$(shasum "$CODEX/diff-skill/SKILL.md" | cut -d' ' -f1)" == "$CODEX_DIFF_HASH_BEFORE" ]]; then
  pass "Dry-run refuse → diff-skill intact côté Codex"
else
  fail "Dry-run a modifié diff-skill"
fi
[[ ! -d "$CODEX/claude-only" ]] && pass "Dry-run refuse → claude-only pas copié" || fail "claude-only a été copié en dry-run"
[[ ! -d "$BACKUPS" ]] && pass "Aucun backup créé en dry-run" || fail "Backup créé en dry-run"

echo
echo "═══ Run 2 : DRY-RUN puis APPLY in-session (claude→codex) ═══"
run_sync <<EOF | sed 's/^/    /'
1
1
1
n
y
4
EOF

# Vérifications post-apply
echo
echo "═══ Vérifications post-apply ═══"

# NEW : claude-only copié, format préservé
if [[ -f "$CODEX/claude-only/SKILL.md" ]]; then
  pass "claude-only copié côté Codex"
else
  fail "claude-only manquant côté Codex"
fi
# Format frontmatter préservé
if grep -q '^name: claude-only$' "$CODEX/claude-only/SKILL.md" \
   && grep -q '^description:' "$CODEX/claude-only/SKILL.md"; then
  pass "Frontmatter YAML préservé"
else
  fail "Frontmatter YAML corrompu"
  cat "$CODEX/claude-only/SKILL.md" | head -5 | sed 's/^/      /'
fi
# Récursivité (asset embarqué)
if [[ -f "$CODEX/claude-only/assets/notes.txt" ]]; then
  pass "Sous-dossier 'assets/' copié récursivement"
else
  fail "Sous-dossier 'assets/' perdu"
fi

# DIFF : diff-skill écrasé par la version Claude
if diff -q "$CLAUDE/diff-skill/SKILL.md" "$CODEX/diff-skill/SKILL.md" >/dev/null; then
  pass "diff-skill : version Codex remplacée par version Claude"
else
  fail "diff-skill : pas correctement écrasé"
fi

# SAME : pas de backup (skip)
SAME_BACKUP_COUNT="$(find "$BACKUPS" -name "same-skill" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$SAME_BACKUP_COUNT" == "0" ]]; then
  pass "same-skill non touché (pas de backup)"
else
  fail "same-skill backupé alors qu'identique"
fi

# Codex-only : intact
if [[ -f "$CODEX/codex-only/SKILL.md" ]]; then
  pass "codex-only intact (pas touché par sync Claude→Codex)"
else
  fail "codex-only supprimé par erreur"
fi

# _archived : exclu
if [[ ! -d "$CODEX/_archived" ]]; then
  pass "_archived correctement exclu"
else
  fail "_archived a été copié (devrait être exclu)"
fi

# Backup contient bien l'ancienne version de diff-skill
BACKUP_DIR="$(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d | head -1)"
if [[ -f "$BACKUP_DIR/diff-skill/SKILL.md" ]]; then
  pass "Backup créé pour diff-skill"
  if [[ "$(shasum "$BACKUP_DIR/diff-skill/SKILL.md" | cut -d' ' -f1)" == "$CODEX_DIFF_HASH_BEFORE" ]]; then
    pass "Backup contient bien l'ancienne version Codex"
  else
    fail "Backup contient un mauvais contenu"
  fi
else
  fail "Backup pour diff-skill manquant"
fi

# ─── Run 3 : Claude → Cursor (NEW dans la 3e cible) ──────────────────────────
echo
echo "═══ Run 3 : APPLY claude→cursor (3e cible) ═══"
run_sync <<EOF | sed 's/^/    /'
1
1
2
n
y
4
EOF

# Vérif : claude-only doit maintenant exister côté Cursor aussi
if [[ -f "$CURSOR/claude-only/SKILL.md" ]]; then
  pass "Cursor : claude-only copié depuis Claude"
else
  fail "Cursor : claude-only manquant"
fi
if grep -q '^name: claude-only$' "$CURSOR/claude-only/SKILL.md" 2>/dev/null; then
  pass "Cursor : frontmatter YAML préservé après sync vers Cursor"
else
  fail "Cursor : frontmatter corrompu"
fi
# Sens inverse intact : codex-only ne doit PAS apparaître côté Cursor
if [[ ! -d "$CURSOR/codex-only" ]]; then
  pass "Cursor : codex-only absent (sync claude→cursor ne touche pas codex)"
else
  fail "Cursor : codex-only apparu par erreur"
fi

# ─── Run 4 : Restore in-session ──────────────────────────────────────────────
echo
echo "═══ Run 4 : Restore via menu 3 ═══"
CLAUDE_DIFF_HASH_AFTER_APPLY="$(shasum "$CODEX/diff-skill/SKILL.md" | cut -d' ' -f1)"

run_sync <<EOF | sed 's/^/    /'
3
1
all
y
4
EOF

# Vérif : diff-skill côté Codex = version d'origine
if [[ "$(shasum "$CODEX/diff-skill/SKILL.md" | cut -d' ' -f1)" == "$CODEX_DIFF_HASH_BEFORE" ]]; then
  pass "Restore : diff-skill rendu à sa version Codex d'origine"
else
  fail "Restore : diff-skill n'a pas été restauré correctement"
fi

# Pre-restore backup doit exister (sécurité)
PRE_RESTORE_COUNT="$(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -name '*pre-restore*' | wc -l | tr -d ' ')"
if (( PRE_RESTORE_COUNT >= 1 )); then
  pass "Pre-restore backup créé (sécurité avant restore)"
else
  fail "Pre-restore backup absent"
fi

echo
if (( FAILS == 0 )); then
  echo "═══════════════════════════════════════"
  echo "  ✓ TOUS LES TESTS PASSENT ($FAILS échec)"
  echo "═══════════════════════════════════════"
else
  echo "═══════════════════════════════════════"
  echo "  ✗ $FAILS ÉCHEC(S)"
  echo "═══════════════════════════════════════"
fi

echo
echo "Workspace test : $TEST_ROOT"
echo "(supprimé automatiquement)"
rm -rf "$TEST_ROOT"
exit $FAILS
