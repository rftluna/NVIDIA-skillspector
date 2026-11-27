#!/usr/bin/env bash
# skillspector-guard.sh — Hook PreToolUse (matcher "Bash") para Claude Code.
# Escanea con NVIDIA SkillSpector (--no-llm) cualquier repo de GitHub que un
# comando vaya a traer a esta PC (git clone, gh repo clone, npx skills add,
# claude mcp add, pip/uv install git+, curl|wget a sh/bash) y decide:
#   LOW                      -> deja pasar en silencio
#   MEDIUM (o HIGH/CRITICAL de otras categorías) -> deja pasar con aviso
#   HIGH/CRITICAL de prompt injection, supply chain, robo de datos o malware
#                            -> permissionDecision "ask" con score y top 3
#   fallo / timeout / sin repo identificable -> deja pasar con aviso de NO revisado
# Nunca rompe el comando por un error propio: siempre exit 0.

# Modos:  (sin args) Claude Code -> "ask" cuando hay riesgo grave
#         --codex    Codex CLI   -> "deny" (Codex no soporta "ask") + reporte
# Repos grandes: se espera hasta --timeout N segundos (el hook se registra con
# --timeout 1780 y timeout 1800 del hook; sin argumento, 100 s). Si aun así no termina, NO se deja pasar en silencio:
# Claude pregunta ("ask"), Codex bloquea.

set -u
MODE=claude
SCAN_TIMEOUT="${SKILLSPECTOR_GUARD_TIMEOUT:-100}"   # por defecto 100 s; el hook pasa --timeout
while [ $# -gt 0 ]; do
  case "$1" in
    --codex) MODE=codex ;;
    --timeout) shift; case "${1:-}" in ''|*[!0-9]*) ;; *) SCAN_TIMEOUT="$1" ;; esac ;;
  esac
  shift
done
LOG="$HOME/.claude/hooks/skillspector-guard.log"
REPORTS="$HOME/.claude/hooks/reports"

# ---------- localizar herramientas ----------
JQ="$(command -v jq 2>/dev/null)"
if [ -z "$JQ" ]; then
  for c in "$HOME"/AppData/Local/Microsoft/WinGet/Links/jq.exe \
           "$HOME"/AppData/Local/Microsoft/WinGet/Packages/jqlang.jq_*/jq.exe; do
    [ -x "$c" ] && { JQ="$c"; break; }
  done
fi
if [ -z "$JQ" ]; then
  # Sin jq no podemos leer el payload; no bloquear.
  printf '%s\n' '{"systemMessage":"⚠ SkillSpector guard: jq no está instalado; no se pudo revisar el comando."}'
  exit 0
fi

SS="${SKILLSPECTOR_GUARD_BIN:-$(command -v skillspector 2>/dev/null)}"
[ -z "$SS" ] && [ -x "$HOME/.local/bin/skillspector.exe" ] && SS="$HOME/.local/bin/skillspector.exe"
[ -z "$SS" ] && [ -x "$HOME/.local/bin/skillspector" ] && SS="$HOME/.local/bin/skillspector"

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/ssguard.$$")"
mkdir -p "$TMPD" 2>/dev/null
cleanup() { rm -rf "$TMPD" 2>/dev/null; }
trap cleanup EXIT

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

emit_msg() {   # aviso no bloqueante
  "$JQ" -cn --arg m "$1" '{systemMessage:$m}' 2>/dev/null \
    || printf '%s\n' '{"systemMessage":"SkillSpector guard: aviso (no se pudo formatear)"}'
  exit 0
}
emit_ask() {   # Claude: pide confirmación. Codex: bloquea (no soporta "ask").
  local r="$1" d="ask"
  if [ "$MODE" = codex ]; then
    d="deny"
    r="⛔ BLOQUEADO por SkillSpector (Codex no puede preguntarte). $r Si aun así lo quieres, revisa el reporte y ejecútalo tú a mano."
  fi
  "$JQ" -cn --arg r "$r" --arg d "$d" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}, systemMessage:$r}' 2>/dev/null \
    || printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"SkillSpector: hallazgos graves (ver log)"}}\n' "$d"
  exit 0
}
save_report() {   # guarda el JSON completo y devuelve la ruta
  mkdir -p "$REPORTS" 2>/dev/null
  local f="$REPORTS/$(printf '%s' "$URL" | sed -E 's#https://github.com/##; s#[^A-Za-z0-9_.-]+#_#g')-$(date +%Y%m%d-%H%M%S).json"
  cp "$OUT" "$f" 2>/dev/null || return 0
  cygpath -w "$f" 2>/dev/null || printf '%s' "$f"
}

# ---------- leer el comando ----------
INPUT="$(cat 2>/dev/null)"
CMD="$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null | tr '\r\n\t' '   ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
[ -z "$CMD" ] && exit 0

# ---------- ¿es un comando que trae código? ----------
S='[[:space:]]'
PATTERNS=(
  "(^|[^[:alnum:]_-])git$S+([^;&|]*$S)?clone($S|$)"
  "(^|[^[:alnum:]_-])gh$S+repo$S+clone($S|$)"
  "(^|[^[:alnum:]_-])npx$S+([^;&|]*$S)?skills(@[^[:space:]]+)?$S+add($S|$)"
  "(^|[^[:alnum:]_-])claude$S+mcp$S+add($S|$)"
  "(^|[^[:alnum:]_-])(pip3?|python3?$S+-m$S+pip|py$S+-m$S+pip|uv$S+pip)$S+install[^;&|]*git\+"
  "(^|[^[:alnum:]_-])uv$S+tool$S+install[^;&|]*git\+"
  "(^|[^[:alnum:]_-])(curl|wget)$S[^|]*\|$S*(sudo$S+)?(ba|z|da)?sh($S|$)"
  "(^|[^[:alnum:]_-])(ba|z)?sh$S+(-c$S+)?[\"']?(\\\$\(|<\()$S*(curl|wget)$S"
)
MATCHED=""
for p in "${PATTERNS[@]}"; do
  if printf '%s' "$CMD" | grep -qiE -- "$p"; then MATCHED=1; break; fi
done
[ -z "$MATCHED" ] && exit 0

SHORT_CMD="$(printf '%s' "$CMD" | cut -c1-120)"

# ---------- extraer repo de GitHub ----------
norm() {  # owner/repo -> https://github.com/owner/repo (sin .git)
  local o="$1" r="$2"
  r="${r%.git}"
  printf 'https://github.com/%s/%s' "$o" "$r"
}
URL=""
# 1) raw.githubusercontent.com/owner/repo/...
m="$(printf '%s' "$CMD" | grep -oiE 'raw\.githubusercontent\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' | head -1)"
if [ -n "$m" ]; then IFS=/ read -r _ o r <<<"$m"; URL="$(norm "$o" "$r")"; fi
# 2) github.com/owner/repo, github.com:owner/repo (https, git@, git+https, ssh://)
if [ -z "$URL" ]; then
  m="$(printf '%s' "$CMD" | grep -oiE 'github\.com[:/][A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' | grep -viE '^github\.com[:/](orgs|settings|marketplace)/' | head -1)"
  if [ -n "$m" ]; then m="${m#*github.com}"; m="${m#?}"; o="${m%%/*}"; r="${m#*/}"; URL="$(norm "$o" "$r")"; fi
fi
# 3) github:owner/repo (npx / claude mcp add)
if [ -z "$URL" ]; then
  m="$(printf '%s' "$CMD" | grep -oiE '(^|[[:space:]"'\''])github:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' | head -1 | sed -E 's/^[[:space:]"'\'']*github://I')"
  if [ -n "$m" ]; then o="${m%%/*}"; r="${m#*/}"; URL="$(norm "$o" "$r")"; fi
fi
# 4) formato corto owner/repo tras "gh repo clone" o "npx skills add"
if [ -z "$URL" ]; then
  tok="$(printf '%s' "$CMD" | grep -oiE "(gh$S+repo$S+clone|skills(@[^[:space:]]+)?$S+add)$S+([^[:space:];&|-][^[:space:];&|]*)" | head -1 | awk '{print $NF}')"
  tok="${tok%%@*}"; tok="${tok%%#*}"; tok="${tok%\"}"; tok="${tok#\"}"; tok="${tok%\'}"; tok="${tok#\'}"
  if printf '%s' "$tok" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/.*)?$'; then
    o="${tok%%/*}"; rest="${tok#*/}"; r="${rest%%/*}"; URL="$(norm "$o" "$r")"
  fi
fi
# limpiar restos (.git, comillas, puntos finales)
URL="$(printf '%s' "$URL" | sed -E 's/\.git$//; s/[.,;:)"'\'']+$//')"

if [ -z "$URL" ]; then
  log "NO-REPO cmd=[$SHORT_CMD]"
  emit_msg "⚠ SkillSpector NO revisó este comando: no encontré un repo de GitHub identificable (\"$SHORT_CMD\"). Se dejó pasar sin revisar."
fi

if [ -z "$SS" ]; then
  log "NO-SKILLSPECTOR url=$URL"
  emit_msg "⚠ SkillSpector NO revisó $URL (skillspector no está instalado o no está en el PATH). Se dejó pasar sin revisar."
fi

# ---------- escanear (con timeout que mata todo el árbol de procesos) ----------
OUT="$TMPD/out.json"; ERR="$TMPD/err.txt"
START=$(date +%s)
"$SS" scan "$URL" --no-llm -f json >"$OUT" 2>"$ERR" </dev/null &
PID=$!
WINPID="$(cat /proc/$PID/winpid 2>/dev/null)"
TIMED_OUT=""
while kill -0 "$PID" 2>/dev/null; do
  if [ $(( $(date +%s) - START )) -ge "$SCAN_TIMEOUT" ]; then
    TIMED_OUT=1
    if [ -n "$WINPID" ] && command -v taskkill >/dev/null 2>&1; then
      taskkill //F //T //PID "$WINPID" >/dev/null 2>&1
    fi
    kill -9 "$PID" 2>/dev/null
    break
  fi
  sleep 1
done
wait "$PID" 2>/dev/null; RC=$?
ELAPSED=$(( $(date +%s) - START ))

if [ -n "$TIMED_OUT" ]; then
  log "TIMEOUT ${ELAPSED}s url=$URL mode=$MODE"
  emit_ask "SkillSpector NO pudo revisar $URL: el escaneo no terminó en ${SCAN_TIMEOUT}s. El repo está SIN revisar; decide tú si seguir."
fi

if ! "$JQ" -e '.risk_assessment.severity' "$OUT" >/dev/null 2>&1; then
  reason="$(tr '\r\n' '  ' <"$ERR" 2>/dev/null | sed -E 's/[[:space:]]+/ /g' | cut -c1-160)"
  [ -z "$reason" ] && reason="salida JSON inválida, código $RC"
  log "FAIL rc=$RC url=$URL err=[$reason]"
  emit_msg "⚠ SkillSpector NO revisó $URL (falló el escaneo: $reason). Se dejó pasar sin revisar."
fi

# ---------- interpretar el JSON ----------
# Categorías "graves": prompt injection, supply chain, robo/exfiltración de datos, malware.
DANGER_RE='prompt injection|dangerous code execution|anti-refusal|tool poisoning|supply chain|rug pull|exfiltrat|agent snooping|credential|yara|malware|backdoor|trojan|webshell|cryptominer|hacktool|obfuscat'

SUMMARY="$("$JQ" -r --arg re "$DANGER_RE" '
  def rank: {"CRITICAL":4,"HIGH":3,"MEDIUM":2,"LOW":1}[ascii_upcase] // 0;
  def clip(n): if length > n then .[0:n] + "…" else . end;
  def line1: (.explanation // .finding // .pattern // "") | gsub("[\r\n\t]+";" ") | clip(90);
  def fmt: "[\(.severity)] \(.category // "?") \(.id // ""): \(line1) (\(.location.file // "?"):\(.location.start_line // "?"))";
  # top 3 con reglas distintas (evita repetir la misma regla 3 veces); "(xN)" = apariciones
  def best3: . as $l
    | sort_by(-((.severity // "") | rank), -(.confidence // 0))
    | reduce .[] as $i ([]; if any(.[]; .id == $i.id) then . else . + [$i] end)
    | .[0:3] | map(. as $f | fmt + " (x\([$l[] | select(.id == $f.id)] | length))");
  (.issues // []) as $all
  | ($all | map(select(((.severity // "") | rank) >= 3 and (((.category // "") + " " + (.id // "")) | test($re; "i"))))) as $danger
  | {
      score: (.risk_assessment.score // "?"),
      sev: (.risk_assessment.severity // "?" | ascii_upcase),
      rec: (.risk_assessment.recommendation // ""),
      maxissue: ([$all[] | .severity // "" | ascii_upcase] | max_by(rank) // "NONE"),
      n: ($all | length),
      ndanger: ($danger | length),
      top: ($all | best3),
      topdanger: ($danger | best3)
    }
  | [ (.score|tostring), .sev, .rec, .maxissue, (.n|tostring), (.ndanger|tostring),
      (.top | to_entries | map("\(.key+1)) \(.value)") | join(" ")),
      ((if (.topdanger|length) > 0 then .topdanger else .top end) | to_entries | map("\(.key+1)) \(.value)") | join(" ")) ]
  | join("\u001f")
' "$OUT" 2>/dev/null)"

if [ -z "$SUMMARY" ]; then
  log "PARSE-FAIL url=$URL"
  emit_msg "⚠ SkillSpector NO revisó $URL (no pude interpretar el JSON del reporte). Se dejó pasar sin revisar."
fi

IFS=$'\x1f' read -r SCORE SEV REC MAXISSUE NISSUES NDANGER TOP TOPDANGER <<<"$SUMMARY"

# Severidad efectiva: la mayor entre la global y la del peor hallazgo grave.
rank() { case "$1" in CRITICAL) echo 4;; HIGH) echo 3;; MEDIUM) echo 2;; LOW) echo 1;; *) echo 0;; esac; }
EFF="$SEV"
if [ "$NDANGER" -gt 0 ] 2>/dev/null && [ "$(rank "$MAXISSUE")" -gt "$(rank "$EFF")" ]; then EFF="$MAXISSUE"; fi

log "SCAN ${ELAPSED}s url=$URL score=$SCORE sev=$SEV max_issue=$MAXISSUE issues=$NISSUES danger=$NDANGER"

if [ "$NDANGER" -gt 0 ] 2>/dev/null && [ "$(rank "$EFF")" -ge 3 ]; then
  RPT="$(save_report)"
  log "DECISION ask mode=$MODE url=$URL report=$RPT"
  emit_ask "SkillSpector $EFF (score $SCORE/100, recomendación $REC) en $URL — $NDANGER hallazgo(s) grave(s) de prompt injection / supply chain / robo de datos / malware. Top 3: $TOPDANGER${RPT:+ — Reporte completo: $RPT}"
fi

case "$SEV" in
  LOW|NONE|"")
    log "DECISION allow-silent url=$URL"
    exit 0 ;;
  *)
    log "DECISION allow-warn url=$URL"
    emit_msg "SkillSpector: $URL score $SCORE/100, $SEV ($NISSUES hallazgos). $TOP" ;;
esac
exit 0
