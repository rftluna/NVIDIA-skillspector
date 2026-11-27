#!/usr/bin/env bash
# Instala el guardia SkillSpector en esta máquina (Claude Code + Codex).
#   - jq y uv (en Windows los instala con winget si faltan)
#   - SkillSpector desde github.com/rftluna/NVIDIA-skillspector (Python 3.12)
#   - ~/.claude/hooks/skillspector-guard.sh
#   - hook PreToolUse en ~/.claude/settings.json (muestra el diff y pide ok)
#   - hook PreToolUse en ~/.codex/hooks.json si hay Codex (muestra el diff y pide ok)
# Conserva todos los hooks y claves existentes y hace copia .bak antes de tocar nada.
#
# Uso (Git Bash):  bash guard/install.sh
# Variables:  ASSUME_YES=1 (no preguntar)  SKIP_TOOLS=1 (no instalar jq/uv/skillspector)
#             TARGET_HOME=/ruta (instalar en otro HOME, para pruebas)

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TH="${TARGET_HOME:-$HOME}"
REPO_URL="git+https://github.com/rftluna/NVIDIA-skillspector.git"
SCAN_TIMEOUT=1780
HOOK_TIMEOUT=1800
IS_WIN=""; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WIN=1 ;; esac

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ⚠ %s\n' "$*"; }
die()  { printf '  ✗ %s\n' "$*"; exit 1; }
confirm() {
  [ "${ASSUME_YES:-}" = 1 ] && return 0
  local a; read -r -p "  $1 [s/N] " a </dev/tty 2>/dev/null || { echo "  (sin terminal interactiva: no aplico; usa ASSUME_YES=1)"; return 1; }
  case "$a" in s|S|si|SI|sí|y|Y|yes) return 0 ;; *) return 1 ;; esac
}

# ---------- 1. herramientas ----------
say "1) Herramientas"
find_jq() {
  JQ="$(command -v jq 2>/dev/null)"
  if [ -z "$JQ" ]; then
    for c in "$HOME"/AppData/Local/Microsoft/WinGet/Links/jq.exe \
             "$HOME"/AppData/Local/Microsoft/WinGet/Packages/jqlang.jq_*/jq.exe; do
      [ -x "$c" ] && { JQ="$c"; break; }
    done
  fi
}
find_jq
if [ -z "$JQ" ] && [ -z "${SKIP_TOOLS:-}" ] && [ -n "$IS_WIN" ]; then
  winget install --id jqlang.jq -e --silent --accept-source-agreements --accept-package-agreements >/dev/null 2>&1
  find_jq
fi
[ -n "$JQ" ] || die "Falta jq. Instálalo (Windows: winget install jqlang.jq) y vuelve a correr."
ok "jq: $("$JQ" --version)"

command -v timeout >/dev/null 2>&1 || warn "No hay 'timeout' (no es crítico: el guardia usa su propio temporizador)."

if [ -z "${SKIP_TOOLS:-}" ]; then
  UV="$(command -v uv 2>/dev/null)"; [ -z "$UV" ] && [ -x "$HOME/.local/bin/uv.exe" ] && UV="$HOME/.local/bin/uv.exe"
  if [ -z "$UV" ] && [ -n "$IS_WIN" ]; then
    winget install --id astral-sh.uv -e --silent --accept-source-agreements --accept-package-agreements >/dev/null 2>&1
    UV="$(command -v uv 2>/dev/null)"
    [ -z "$UV" ] && for c in "$HOME"/.local/bin/uv.exe "$HOME"/AppData/Local/Microsoft/WinGet/Packages/astral-sh.uv_*/uv.exe; do [ -x "$c" ] && { UV="$c"; break; }; done
  fi
  [ -n "$UV" ] || die "Falta uv. Instálalo (Windows: winget install astral-sh.uv) y vuelve a correr."
  ok "uv: $("$UV" --version)"
  echo "  Instalando SkillSpector desde $REPO_URL (Python 3.12; tarda 1-2 min)..."
  "$UV" tool install --python 3.12 --force "$REPO_URL" >/dev/null 2>&1 || die "Falló la instalación de SkillSpector."
fi
SS="$(command -v skillspector 2>/dev/null)"; [ -z "$SS" ] && [ -x "$HOME/.local/bin/skillspector.exe" ] && SS="$HOME/.local/bin/skillspector.exe"
[ -n "$SS" ] && ok "SkillSpector: $("$SS" --version 2>&1)" || warn "skillspector no está en el PATH todavía (abre una terminal nueva)."

# ---------- 2. script del guardia ----------
say "2) Script del guardia"
mkdir -p "$TH/.claude/hooks"
GUARD="$TH/.claude/hooks/skillspector-guard.sh"
cp "$HERE/skillspector-guard.sh" "$GUARD" && chmod +x "$GUARD"
ok "$GUARD"
if [ -n "$IS_WIN" ]; then GUARD_P="$(cygpath -m "$GUARD")"; else GUARD_P="$GUARD"; fi

# ---------- helper: fusionar hook PreToolUse/Bash en un JSON ----------
# $1 archivo  $2 matcher  $3 objeto-hook (JSON)
merge_hook() {
  local f="$1" matcher="$2" hook="$3" src tmp
  src="$(mktemp)"; tmp="$(mktemp)"
  if [ -s "$f" ]; then tr -d '\r' <"$f" >"$src"; else echo '{}' >"$src"; fi
  "$JQ" empty "$src" 2>/dev/null || { rm -f "$src" "$tmp"; die "$f no es JSON válido; no lo toco."; }
  "$JQ" --arg m "$matcher" --argjson h "$hook" '
    .hooks //= {} | .hooks.PreToolUse //= []
    # quitar instalaciones previas del guardia (para no duplicar)
    | .hooks.PreToolUse |= map(.hooks = ((.hooks // []) | map(select(((.command // "") + (.commandWindows // "")) | test("skillspector-guard") | not))))
    | .hooks.PreToolUse |= map(select((.hooks | length) > 0))
    | if any(.hooks.PreToolUse[]; .matcher == $m)
      then .hooks.PreToolUse |= map(if .matcher == $m then .hooks += [$h] else . end)
      else .hooks.PreToolUse += [{matcher: $m, hooks: [$h]}] end' "$src" | tr -d '\r' >"$tmp"
  [ -s "$tmp" ] || die "jq falló con $f"
  echo "  Diff propuesto para $f:"
  diff -u "$src" "$tmp" | sed 's/^/    /'
  if diff -q "$src" "$tmp" >/dev/null; then ok "sin cambios"; rm -f "$src" "$tmp"; return 0; fi
  if confirm "¿Aplico este cambio en $f?"; then
    [ -e "$f" ] && cp -p "$f" "$f.bak-skillspector-$(date +%Y%m%d%H%M%S)"
    mkdir -p "$(dirname "$f")"; cp "$tmp" "$f"; ok "aplicado (copia .bak al lado)"
  else
    warn "no se aplicó"
  fi
  rm -f "$src" "$tmp"
}

# ---------- 3. Claude Code ----------
say "3) Claude Code (~/.claude/settings.json)"
CLAUDE_HOOK="$("$JQ" -cn --arg c "bash \"$GUARD_P\" --timeout $SCAN_TIMEOUT" --argjson t "$HOOK_TIMEOUT" '{type:"command",command:$c,timeout:$t}')"
merge_hook "$TH/.claude/settings.json" "Bash" "$CLAUDE_HOOK"

# ---------- 4. Codex ----------
say "4) Codex (~/.codex/hooks.json)"
if [ -d "$TH/.codex" ] || command -v codex >/dev/null 2>&1; then
  WINCMD=""
  if [ -n "$IS_WIN" ]; then
    BASH_W="$(cygpath -w /)bin\\bash.exe"
    SHORT="$(powershell -NoProfile -c "(New-Object -ComObject Scripting.FileSystemObject).GetFile('$BASH_W').ShortPath" 2>/dev/null | tr -d '\r')"
    case "$SHORT" in *" "*|"") SHORT="\"$BASH_W\"" ;; esac
    WINCMD="$SHORT $GUARD_P --codex --timeout $SCAN_TIMEOUT"
  fi
  CODEX_HOOK="$("$JQ" -cn --arg c "bash \"\$HOME/.claude/hooks/skillspector-guard.sh\" --codex --timeout $SCAN_TIMEOUT" \
     --arg w "$WINCMD" --argjson t "$HOOK_TIMEOUT" \
     '{type:"command",command:$c} + (if $w != "" then {commandWindows:$w} else {} end) + {timeout:$t,statusMessage:"SkillSpector revisando el repo antes de traerlo..."}')"
  mkdir -p "$TH/.codex"
  merge_hook "$TH/.codex/hooks.json" "^Bash$" "$CODEX_HOOK"
  warn "En Codex: abre 'codex', escribe /hooks y marca como confiable el hook de SkillSpector."
else
  ok "Codex no está instalado; se omite."
fi

# ---------- 5. prueba rápida ----------
say "5) Prueba rápida"
out="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | bash "$GUARD"; echo "exit=$?")"
[ "$out" = "exit=0" ] && ok "comando normal: pasa sin tocarlo" || warn "salida inesperada: $out"
say "Listo. Reinicia Claude Code / Codex para que carguen el hook."
