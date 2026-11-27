# Guardia SkillSpector (Claude Code + Codex)

Hook `PreToolUse` que escanea con SkillSpector (`--no-llm`) cualquier repo de GitHub
antes de que un comando lo traiga a la máquina: `git clone`, `gh repo clone`,
`npx skills add`, `claude mcp add`, `pip install git+`, `uv tool install git+`,
`curl`/`wget` a `sh`/`bash`. Cualquier otro comando pasa sin tocarse.

| Resultado | Claude Code | Codex |
|---|---|---|
| LOW | pasa en silencio | pasa en silencio |
| MEDIUM (u otras categorías) | pasa con aviso corto | pasa con aviso corto |
| HIGH/CRITICAL de prompt injection, supply chain, robo de datos o malware | pregunta (`ask`) con score + top 3 | bloquea (`deny`) con score + top 3 |
| El escaneo no termina en ~30 min | pregunta | bloquea |
| Falla el escaneo o no hay repo de GitHub identificable | pasa con aviso "NO se revisó" | igual |

Los reportes completos de los casos graves quedan en `~/.claude/hooks/reports/` y cada
decisión en `~/.claude/hooks/skillspector-guard.log`.

## Instalar en otra máquina (Windows con Git Bash)

```bash
git clone https://github.com/rftluna/NVIDIA-skillspector
bash NVIDIA-skillspector/guard/install.sh
```

El instalador pone jq y uv si faltan (winget), instala SkillSpector desde este repo con
Python 3.12, copia el script, y **muestra el diff** de `~/.claude/settings.json` y
`~/.codex/hooks.json` pidiendo ok antes de guardar (hace copia `.bak`). Conserva todos los
hooks existentes y se puede correr varias veces sin duplicar nada.

Después: reiniciar Claude Code / Codex y, en Codex, aprobar el hook con `/hooks`.

## Actualizar SkillSpector

Este repo se sincroniza con NVIDIA cada lunes (workflow `Sync semanal desde NVIDIA`).
La herramienta instalada solo cambia cuando lo decides:

```bash
uv tool install --python 3.12 --force git+https://github.com/rftluna/NVIDIA-skillspector.git
```
