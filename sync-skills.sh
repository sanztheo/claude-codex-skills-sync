#!/usr/bin/env bash
# sync-skills.sh — Synchronise les skills entre Claude Code CLI et Codex.
# Direction au choix, backup automatique des skills écrasés, mode dry-run par défaut.

set -euo pipefail

# ─── Configuration (overridable via env vars pour tests) ─────────────────────
CLAUDE_DIR="${SKILLS_SYNC_CLAUDE_DIR:-$HOME/.claude/skills}"
CODEX_DIR="${SKILLS_SYNC_CODEX_DIR:-$HOME/.codex/skills}"
BACKUP_ROOT="${SKILLS_SYNC_BACKUP_ROOT:-$HOME/.skills-sync-backups}"

# ─── Couleurs ─────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

# ─── Flags ────────────────────────────────────────────────────────────────────
DRY_RUN=1
for arg in "$@"; do
  case "$arg" in
    --apply) DRY_RUN=0 ;;
    --help|-h)
      cat <<EOF
Usage: $0 [--apply]
  --apply  Exécute réellement les changements (par défaut : dry-run).
  --help   Affiche cette aide.

Menu interactif :
  1) Claude → Codex
  2) Codex → Claude
  3) Lister les backups
  4) Restaurer un backup
  5) Quitter
EOF
      exit 0
      ;;
  esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────
banner() {
  echo
  echo "${BOLD}${BLUE}═══ Skills Sync Tool ═══${NC}"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "${YELLOW}(DRY-RUN — apply proposé à la fin de chaque opération, ou --apply au lancement)${NC}"
  else
    echo "${RED}${BOLD}(APPLY MODE — modifications réelles activées)${NC}"
  fi
}

skills_identical() {
  diff -rq "$1" "$2" >/dev/null 2>&1
}

# Ignore les skills internes/cachés.
skill_excluded() {
  local name="$1"
  [[ "$name" == _* ]] && return 0
  [[ "$name" == .* ]] && return 0
  return 1
}

confirm() {
  local prompt="$1" reply
  read -rp "$prompt [y/N]: " reply
  [[ "$reply" =~ ^[YyOo] ]]
}

# ─── Sync core ────────────────────────────────────────────────────────────────
sync_direction() {
  local src_root="$1" dst_root="$2" label="$3"
  local ts session_backup
  ts="$(date +%Y-%m-%d_%H-%M-%S)"
  session_backup="$BACKUP_ROOT/${ts}_${label}"

  if [[ ! -d "$src_root" ]]; then
    echo "${RED}Source introuvable : $src_root${NC}"
    return 1
  fi
  mkdir -p "$dst_root"

  local new_list=() diff_list=() same_list=()

  for src_skill in "$src_root"/*/; do
    [[ -d "$src_skill" ]] || continue
    local name
    name="$(basename "$src_skill")"
    skill_excluded "$name" && continue

    local dst_skill="$dst_root/$name"
    if [[ ! -d "$dst_skill" ]]; then
      new_list+=("$name")
    elif skills_identical "$src_skill" "$dst_skill"; then
      same_list+=("$name")
    else
      diff_list+=("$name")
    fi
  done

  echo
  echo "${BOLD}Plan ($label) :${NC}"
  echo "  ${GREEN}NEW${NC}   : ${#new_list[@]} nouveaux (copie)"
  echo "  ${YELLOW}DIFF${NC}  : ${#diff_list[@]} différents (backup + overwrite)"
  echo "  ${CYAN}SAME${NC}  : ${#same_list[@]} identiques (skip)"

  if (( ${#new_list[@]} + ${#diff_list[@]} == 0 )); then
    echo "${GREEN}Rien à faire.${NC}"
    return 0
  fi

  if confirm "Voir le détail ?"; then
    (( ${#new_list[@]}  )) && for n in "${new_list[@]}";  do echo "  ${GREEN}+ $n${NC}"; done
    (( ${#diff_list[@]} )) && for n in "${diff_list[@]}"; do echo "  ${YELLOW}~ $n${NC}"; done
    (( ${#same_list[@]} )) && for n in "${same_list[@]}"; do echo "  ${CYAN}= $n${NC}"; done
  fi

  echo
  local apply_now=0
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "${YELLOW}(DRY-RUN — rien n'a été modifié pour l'instant.)${NC}"
    if confirm "Voulez-vous APPLIQUER ces changements maintenant ?"; then
      apply_now=1
    fi
  else
    if confirm "Appliquer ces changements vers $dst_root ?"; then
      apply_now=1
    fi
  fi

  if (( apply_now == 0 )); then
    echo "Annulé."
    return 0
  fi

  mkdir -p "$session_backup"
  printf 'src=%s\ndst=%s\nlabel=%s\nts=%s\n' \
    "$src_root" "$dst_root" "$label" "$ts" > "$session_backup/.session_info"

  for n in "${new_list[@]}"; do
    cp -a "$src_root/$n" "$dst_root/$n"
    echo "  ${GREEN}+ $n${NC}"
  done

  for n in "${diff_list[@]}"; do
    cp -a "$dst_root/$n" "$session_backup/$n"
    rm -rf "$dst_root/$n"
    cp -a "$src_root/$n" "$dst_root/$n"
    echo "  ${YELLOW}~ $n${NC} (backup → $session_backup/$n)"
  done

  # Si aucun backup réel n'a été créé, nettoyage du dossier vide.
  if (( ${#diff_list[@]} == 0 )); then
    rm -f "$session_backup/.session_info"
    rmdir "$session_backup" 2>/dev/null || true
  else
    echo "${GREEN}Backups : $session_backup${NC}"
  fi
}

# ─── Backups : list ───────────────────────────────────────────────────────────
list_backup_sessions() {
  [[ -d "$BACKUP_ROOT" ]] || { echo "${YELLOW}Aucun backup ($BACKUP_ROOT n'existe pas).${NC}"; return 1; }
  local -a sessions=()
  while IFS= read -r dir; do
    [[ -n "$dir" ]] && sessions+=("$dir")
  done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

  if (( ${#sessions[@]} == 0 )); then
    echo "${YELLOW}Aucun backup dans $BACKUP_ROOT.${NC}"
    return 1
  fi

  echo
  echo "${BOLD}Backups disponibles :${NC}"
  local i=0
  for s in "${sessions[@]}"; do
    i=$((i+1))
    local base count info=""
    base="$(basename "$s")"
    count="$(find "$s" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    if [[ -f "$s/.session_info" ]]; then
      info=" — $(grep -E '^label=' "$s/.session_info" | cut -d= -f2-)"
    fi
    printf "  ${BOLD}[%d]${NC} %s (%s skills)%s\n" "$i" "$base" "$count" "$info"
  done

  SESSIONS_GLOBAL=("${sessions[@]}")
  return 0
}

list_backups() {
  list_backup_sessions || return 0
}

# ─── Backups : restore ────────────────────────────────────────────────────────
restore_backup() {
  list_backup_sessions || return 0
  echo
  local choice
  read -rp "Numéro de la session à restaurer (vide pour annuler) : " choice
  [[ -z "$choice" ]] && { echo "Annulé."; return 0; }
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#SESSIONS_GLOBAL[@]} )); then
    echo "${RED}Choix invalide.${NC}"
    return 0
  fi

  local session="${SESSIONS_GLOBAL[$((choice-1))]}"
  if [[ ! -f "$session/.session_info" ]]; then
    echo "${RED}Session corrompue (pas de .session_info).${NC}"
    return 0
  fi

  local dst_root
  dst_root="$(grep -E '^dst=' "$session/.session_info" | cut -d= -f2-)"
  if [[ -z "$dst_root" ]]; then
    echo "${RED}Destination introuvable dans .session_info.${NC}"
    return 0
  fi

  echo
  echo "Session : $session"
  echo "Destination originelle : $dst_root"
  echo
  echo "Skills disponibles dans ce backup :"
  local -a skills=()
  while IFS= read -r dir; do
    [[ -n "$dir" ]] && skills+=("$(basename "$dir")")
  done < <(find "$session" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

  if (( ${#skills[@]} == 0 )); then
    echo "${YELLOW}Aucun skill dans cette session.${NC}"
    return 0
  fi

  local i=0
  for s in "${skills[@]}"; do
    i=$((i+1))
    printf "  [%d] %s\n" "$i" "$s"
  done

  echo
  read -rp "Restaurer : (a)ll, numéro, ou nom du skill : " pick
  [[ -z "$pick" ]] && { echo "Annulé."; return 0; }

  local -a to_restore=()
  if [[ "$pick" == "a" || "$pick" == "all" ]]; then
    to_restore=("${skills[@]}")
  elif [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#skills[@]} )); then
    to_restore=("${skills[$((pick-1))]}")
  else
    local found=0
    for s in "${skills[@]}"; do
      if [[ "$s" == "$pick" ]]; then
        to_restore=("$s")
        found=1
        break
      fi
    done
    if (( found == 0 )); then
      echo "${RED}Skill introuvable dans cette session.${NC}"
      return 0
    fi
  fi

  echo
  echo "Sera restauré vers $dst_root :"
  for s in "${to_restore[@]}"; do echo "  • $s"; done

  echo
  local apply_now=0
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "${YELLOW}(DRY-RUN — rien n'a été modifié pour l'instant.)${NC}"
    if confirm "Voulez-vous RESTAURER maintenant ?"; then
      apply_now=1
    fi
  else
    if confirm "Confirmer la restauration ?"; then
      apply_now=1
    fi
  fi

  if (( apply_now == 0 )); then
    echo "Annulé."
    return 0
  fi

  # Backup pré-restore (sécurité : on backup l'état actuel avant de l'écraser).
  local ts pre_backup
  ts="$(date +%Y-%m-%d_%H-%M-%S)"
  pre_backup="$BACKUP_ROOT/${ts}_pre-restore"
  mkdir -p "$pre_backup"
  printf 'src=%s\ndst=%s\nlabel=%s\nts=%s\n' \
    "$session" "$dst_root" "pre-restore" "$ts" > "$pre_backup/.session_info"

  local saved=0
  for s in "${to_restore[@]}"; do
    if [[ -d "$dst_root/$s" ]]; then
      cp -a "$dst_root/$s" "$pre_backup/$s"
      rm -rf "$dst_root/$s"
      saved=1
    fi
    cp -a "$session/$s" "$dst_root/$s"
    echo "  ${GREEN}↺ $s${NC}"
  done

  if (( saved == 0 )); then
    rm -f "$pre_backup/.session_info"
    rmdir "$pre_backup" 2>/dev/null || true
  else
    echo "${GREEN}État précédent sauvegardé dans : $pre_backup${NC}"
  fi
  echo "${GREEN}Restauration terminée.${NC}"
}

# ─── Menu principal ───────────────────────────────────────────────────────────
main_menu() {
  while true; do
    banner
    echo
    echo "  1) Claude → Codex   ($CLAUDE_DIR → $CODEX_DIR)"
    echo "  2) Codex → Claude   ($CODEX_DIR → $CLAUDE_DIR)"
    echo "  3) Lister les backups"
    echo "  4) Restaurer un backup"
    echo "  5) Quitter"
    echo
    read -rp "Choix [1-5] : " choice
    case "$choice" in
      1) sync_direction "$CLAUDE_DIR" "$CODEX_DIR" "claude-to-codex" ;;
      2) sync_direction "$CODEX_DIR" "$CLAUDE_DIR" "codex-to-claude" ;;
      3) list_backups ;;
      4) restore_backup ;;
      5|q|Q|"") echo "Bye."; exit 0 ;;
      *) echo "${RED}Choix invalide.${NC}" ;;
    esac
  done
}

main_menu
