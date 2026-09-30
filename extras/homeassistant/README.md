# Home Assistant

Home Assistant runs on its own box, not in this repo. This folder connects
the two.

- **HTTPS**: set `HA_URL` (e.g. `http://192.168.1.50:8123`) and it's served at
  `https://ha.<DOMAIN>` with a dashboard tile. In HA, add the server's LAN
  IP as a trusted proxy (Settings > System > Network), or HA answers 400.
  For live stats on the tile, a long-lived token:
  `./lab config homepage HOMEPAGE_VAR_HA_TOKEN`, then `./lab up homepage`.
- **Local LLM**: with the `ollama` stack and `LAN_BIND` set to the server's
  LAN IP, add HA's Ollama integration at `http://<server>:11434`
  (`qwen2.5:7b` handles tool calls; turn on "prefer handling commands
  locally" in the Assist pipeline so simple commands never wait for it).
- **Voice**: with the `speech` stack, add HA's Wyoming integration at
  `<server>:10300` for speech-to-text and text-to-speech. Whisper doesn't
  know brand names, so give devices plain-word aliases ("air conditioner").
- **Backup alerts**: a webhook automation, see `extras/backup/README.md`.

## hass_ws.py

A tiny stdlib websocket client for settings that only exist on HA's
websocket API (Assist pipelines, entity exposure and aliases, backup
config, repairs). It runs *on* the HA box through the Advanced SSH add-on,
using the add-on's own token, so no token leaves it:

```bash
ssh homeassistant "python3 - '[{\"type\": \"assist_pipeline/pipeline/list\"}]'" < extras/homeassistant/hass_ws.py
```
