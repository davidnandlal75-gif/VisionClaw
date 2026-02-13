# VisionClaw

A real-time AI assistant for Meta Ray-Ban smart glasses. See what you see, hear what you say, and take actions on your behalf -- all through voice.

![VisionClaw](assets/teaserimage.png)

Built on [Meta Wearables DAT SDK](https://github.com/facebook/meta-wearables-dat-ios) + [Gemini Live API](https://ai.google.dev/gemini-api/docs/live) + [OpenAI Realtime API](https://platform.openai.com/docs/guides/realtime) + [OpenClaw](https://github.com/nichochar/openclaw) (optional).

## What This Fork Adds

This is a fork of [sseanliu/VisionClaw](https://github.com/sseanliu/VisionClaw) that fills critical gaps and adds new capabilities:

### Gaps Filled
- **No remote access** -- The original only works over LAN (same Wi-Fi). Leave your house and OpenClaw is unreachable. This fork adds **Cloudflare Tunnel** support so the AI assistant works from anywhere -- cellular, work, travel.
- **Dies when phone locks** -- iOS suspends the app when the screen locks, killing the voice session mid-conversation. This fork adds the `audio` background mode so sessions survive lock screen.
- **AI amnesia about the user** -- The original system prompt aggressively tells Gemini "you have NO memory, NO knowledge" causing it to refuse personal questions instead of routing them to OpenClaw. This fork rewrites the prompt so Gemini knows to ask OpenClaw about the user's files, contacts, preferences, and history.
- **Hardcoded config scattered everywhere** -- API keys and OpenClaw URLs were spread across multiple files. This fork introduces a clean `Secrets.swift` + `AppConfig.swift` pattern with centralized config and smart URL selection.

### Power Added
- **OpenAI GPT-4o Realtime** -- Switch between Gemini and GPT-4o with a tap. Full voice + vision + tool calling with both providers.
- **Cloudflare Tunnel relay** -- One script to set up a secure public HTTPS endpoint for OpenClaw. Zero port forwarding, zero VPN, zero custom relay servers. Works on Cloudflare's free plan.
- **Auto-start tunnel on boot** -- launchd plist so the tunnel comes up automatically when your Mac starts. Set it and forget it.
- **Background audio** -- Voice conversations continue when the phone is locked. Walk around with glasses on, phone in pocket.
- **Provider picker UI** -- Clean UI for switching AI backends on the fly.
- **Conversation memory through OpenClaw** -- The AI can now ask OpenClaw "what do you know about this person?" instead of claiming ignorance.

## What It Does

Put on your glasses, tap the AI button, and talk:

- **"What am I looking at?"** -- Gemini/GPT-4o sees through your glasses camera and describes the scene
- **"Add milk to my shopping list"** -- delegates to OpenClaw, which adds it via your connected apps
- **"Send a message to John saying I'll be late"** -- routes through OpenClaw to WhatsApp/Telegram/iMessage
- **"Search for the best coffee shops nearby"** -- web search via OpenClaw, results spoken back
- **"What do you know about me?"** -- queries OpenClaw's knowledge of your files, contacts, and preferences

The glasses camera streams at ~1fps for visual context, while audio flows bidirectionally in real-time.

## How It Works

![How It Works](assets/how.png)

```
Meta Ray-Ban Glasses (or iPhone camera)
       |
       | video frames + mic audio
       v
iOS App (this project)
       |
       | JPEG frames (~1fps) + PCM audio
       v
Gemini Live / OpenAI Realtime (WebSocket)
       |
       |-- Audio response --> iOS App --> Speaker
       |-- Tool calls -----> iOS App --> OpenClaw Gateway
       |                                    |
       |                    (LAN or Cloudflare Tunnel)
       |                                    v
       |                            56+ skills: web search,
       |                            messaging, smart home,
       |                            notes, reminders, etc.
       |                                    |
       |<--- Tool response <-- iOS App <----+
       |
       v
  AI speaks the result
```

## Quick Start

### 1. Clone and open

```bash
git clone https://github.com/bhartiyashesh/VisionClaw.git
cd VisionClaw/samples/CameraAccess
open CameraAccess.xcodeproj
```

### 2. Configure API keys

Copy the example secrets file and fill in your values:

```bash
cd samples/CameraAccess/CameraAccess
cp Secrets.swift.example Secrets.swift
```

Edit `Secrets.swift`:

```swift
enum Secrets {
  // REQUIRED: Get your key at https://aistudio.google.com/apikey
  static let geminiAPIKey = "your-gemini-key"

  // OPTIONAL: OpenAI API key for GPT-4o Realtime
  static let openaiAPIKey = "your-openai-key"

  // OPTIONAL: OpenClaw (see "Setup: OpenClaw" below)
  static let openClawHost = "http://Your-Mac.local"
  static let openClawPort = 18789
  static let openClawHookToken = "your-token"
  static let openClawGatewayToken = "your-token"

  // OPTIONAL: Cloudflare Tunnel relay (see "Remote Access" below)
  static let openClawRelayURL = ""
}
```

`Secrets.swift` is gitignored and will not be committed.

### 3. Build and run

Select your iPhone as the target device and hit Run (Cmd+R).

### 4. Try it out

**Without glasses (iPhone mode):**
1. Tap **"Start on iPhone"** -- uses your iPhone's back camera
2. Tap the **AI button** to start a session
3. Talk to the AI -- it can see through your iPhone camera

**With Meta Ray-Ban glasses:**

First, enable Developer Mode in the Meta AI app:

1. Open the **Meta AI** app on your iPhone
2. Go to **Settings** (gear icon, bottom left)
3. Tap **App Info**
4. Tap the **App version** number **5 times** -- this unlocks Developer Mode
5. Go back to Settings -- you'll now see a **Developer Mode** toggle. Turn it on.

![How to enable Developer Mode](assets/dev_mode.png)

Then in VisionClaw:
1. Tap **"Start Streaming"** in the app
2. Tap the **AI button** for voice + vision conversation

### 5. Choose your AI provider

The app supports both **Gemini** and **OpenAI GPT-4o Realtime**. Use the provider picker in the app to switch between them. Gemini is the default. Both support voice conversation and tool calling through OpenClaw.

## Setup: OpenClaw (Optional)

OpenClaw gives the AI the ability to take real-world actions: send messages, search the web, manage lists, control smart home devices, and more. Without it, the AI is voice + vision only.

### 1. Install and configure OpenClaw

Follow the [OpenClaw setup guide](https://github.com/nichochar/openclaw). Make sure the gateway is enabled:

In `~/.openclaw/openclaw.json`:

```json
{
  "gateway": {
    "port": 18789,
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "your-gateway-token-here"
    },
    "http": {
      "endpoints": {
        "chatCompletions": { "enabled": true }
      }
    }
  }
}
```

Key settings:
- `bind: "lan"` -- exposes the gateway on your local network so your iPhone can reach it
- `chatCompletions.enabled: true` -- enables the `/v1/chat/completions` endpoint (off by default)
- `auth.token` -- the token your iOS app will use to authenticate

### 2. Configure the iOS app

In `Secrets.swift`, update the OpenClaw settings:

```swift
static let openClawHost = "http://Your-Mac.local"           // your Mac's Bonjour hostname
static let openClawPort = 18789
static let openClawGatewayToken = "your-gateway-token-here"  // must match gateway.auth.token
```

To find your Mac's Bonjour hostname: **System Settings > General > Sharing** -- it's shown at the top (e.g., `Johns-MacBook-Pro.local`). Or run `scutil --get LocalHostName` in Terminal.

### 3. Start the gateway

```bash
openclaw gateway restart
```

Verify it's running:

```bash
curl http://localhost:18789/health
```

Now when you talk to the AI, it can execute tasks through OpenClaw.

## Remote Access via Cloudflare Tunnel (Optional)

By default, the app connects to OpenClaw over your local network (same Wi-Fi). With a Cloudflare Tunnel, you can reach OpenClaw from anywhere -- on cellular, at work, wherever.

```
Mac Mini:  cloudflared tunnel → Cloudflare Edge → https://openclaw.yasheshbharti.com
iPhone:    VisionClaw app → https://openclaw.yasheshbharti.com → tunnel → Mac Mini :18789
```

### Prerequisites

- A domain on Cloudflare (free plan works)
- A Cloudflare API token with **Zone:DNS:Edit** and **Account:Cloudflare Tunnel:Edit** permissions ([create one here](https://dash.cloudflare.com/profile/api-tokens))

### Option A: Automated setup script

Run on your Mac (the one hosting OpenClaw):

```bash
./relay/setup-tunnel.sh
```

This installs `cloudflared`, authenticates with Cloudflare, creates a named tunnel, and prints next steps.

### Option B: Manual setup via Cloudflare API

```bash
# 1. Get your Zone ID and Account ID
curl -s "https://api.cloudflare.com/client/v4/zones?name=yasheshbharti.com" \
  -H "Authorization: Bearer YOUR_API_TOKEN" | python3 -m json.tool

# 2. Create the tunnel
TUNNEL_SECRET=$(openssl rand -base64 32)
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/ACCOUNT_ID/cfd_tunnel" \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"openclaw-tunnel\",\"tunnel_secret\":\"$TUNNEL_SECRET\",\"config_src\":\"cloudflare\"}"

# 3. Configure the tunnel ingress
curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/ACCOUNT_ID/cfd_tunnel/TUNNEL_ID/configurations" \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"config":{"ingress":[{"hostname":"openclaw.yasheshbharti.com","service":"http://localhost:18789"},{"service":"http_status:404"}]}}'

# 4. Create DNS record
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/ZONE_ID/dns_records" \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type":"CNAME","name":"openclaw","content":"TUNNEL_ID.cfargotunnel.com","proxied":true}'
```

### Configure the app

Set the relay URL in `Secrets.swift`:

```swift
static let openClawRelayURL = "https://openclaw.yasheshbharti.com"
```

The app automatically prefers the relay URL when configured, and falls back to LAN when it's empty.

### Start the tunnel

```bash
# One-time:
CLOUDFLARE_TUNNEL_TOKEN="your-token" ./relay/start-tunnel.sh

# Auto-start on boot:
# 1. Edit relay/com.cloudflare.openclaw-tunnel.plist — replace YOUR_TUNNEL_TOKEN
# 2. Install:
cp relay/com.cloudflare.openclaw-tunnel.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.cloudflare.openclaw-tunnel.plist
```

### Verify

```bash
curl https://openclaw.yasheshbharti.com/v1/chat/completions
# Should return HTTP 405 (Method Not Allowed) — that means OpenClaw is responding through the tunnel
```

## Background Operation

The app continues working when the phone is locked -- the audio session stays alive so voice conversations through the glasses are uninterrupted. Background modes enabled: `audio`, `bluetooth-peripheral`, `external-accessory`.

## Architecture

### Key Files

All source code is in `samples/CameraAccess/CameraAccess/`:

| File | Purpose |
|------|---------|
| `Config/AppConfig.swift` | Centralized config: URLs, relay vs LAN selection |
| `Config/AIProvider.swift` | Gemini / OpenAI provider switching |
| `Secrets.swift.example` | Template for API keys (copy to `Secrets.swift`) |
| `Gemini/GeminiConfig.swift` | Gemini model config + system prompt |
| `Gemini/GeminiLiveService.swift` | WebSocket client for Gemini Live API |
| `Gemini/AudioManager.swift` | Mic capture (PCM 16kHz) + audio playback (PCM 24kHz) |
| `Gemini/GeminiSessionViewModel.swift` | Gemini session lifecycle + tool call wiring |
| `OpenAI/OpenAIConfig.swift` | OpenAI Realtime model config |
| `OpenAI/OpenAIRealtimeService.swift` | WebSocket client for OpenAI Realtime API |
| `OpenClaw/ToolCallModels.swift` | Tool declarations, data types |
| `OpenClaw/OpenClawBridge.swift` | HTTP client for OpenClaw gateway (LAN or relay) |
| `OpenClaw/ToolCallRouter.swift` | Routes AI tool calls to OpenClaw |
| `Views/Components/ProviderPickerView.swift` | UI for switching between Gemini and OpenAI |
| `ViewModels/RealtimeSessionViewModel.swift` | OpenAI Realtime session lifecycle |
| `iPhone/IPhoneCameraManager.swift` | AVCaptureSession wrapper for iPhone camera mode |

### Audio Pipeline

- **Input**: iPhone mic -> AudioManager (PCM Int16, mono) -> AI WebSocket
- **Output**: AI WebSocket -> AudioManager playback queue -> iPhone speaker
- **iPhone mode**: Uses `.voiceChat` audio session for echo cancellation + mic gating during AI speech
- **Glasses mode**: Uses `.videoChat` audio session (mic is on glasses, speaker is on phone -- no echo)

### Video Pipeline

- **Glasses**: DAT SDK `videoFramePublisher` (24fps) -> throttle to ~1fps -> JPEG (50% quality) -> AI
- **iPhone**: `AVCaptureSession` back camera (30fps) -> throttle to ~1fps -> JPEG -> AI

### Tool Calling

Both Gemini and OpenAI support function calling. The app declares a single `execute` tool that routes everything through OpenClaw:

1. User says "Add eggs to my shopping list"
2. AI speaks "Sure, adding that now" (verbal acknowledgment before tool call)
3. AI sends `execute(task: "Add eggs to the shopping list")`
4. `ToolCallRouter` sends HTTP POST to OpenClaw gateway (via LAN or Cloudflare Tunnel)
5. OpenClaw executes the task using its 56+ connected skills
6. Result returns to the AI via tool response
7. AI speaks the confirmation

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Gemini API key ([get one free](https://aistudio.google.com/apikey)) and/or OpenAI API key
- Meta Ray-Ban glasses (optional -- use iPhone mode for testing)
- OpenClaw on your Mac (optional -- for agentic actions)
- Cloudflare account + domain (optional -- for remote access)

## Troubleshooting

**"Gemini API key not configured"** -- Copy `Secrets.swift.example` to `Secrets.swift` and add your API key.

**OpenClaw connection timeout** -- Make sure your iPhone and Mac are on the same Wi-Fi network, the gateway is running (`openclaw gateway restart`), and the hostname in `Secrets.swift` matches your Mac's Bonjour name.

**OpenClaw unreachable on cellular** -- Set up a Cloudflare Tunnel (see "Remote Access" section above) and set `openClawRelayURL` in `Secrets.swift`.

**Echo/feedback in iPhone mode** -- The app mutes the mic while the AI is speaking. If you still hear echo, try turning down the volume.

**AI doesn't hear me** -- Check that microphone permission is granted. The app uses aggressive voice activity detection -- speak clearly and at normal volume.

**AI says "I don't know anything about you"** -- Make sure OpenClaw is connected (green badge in the UI). The AI routes personal questions through OpenClaw, which has access to your files and apps.

**OpenClaw opens duplicate browser tabs** -- This is a known upstream issue in OpenClaw's CDP connection management. Using `profile: "openclaw"` (managed Chrome) instead of the default extension relay may improve stability.

For DAT SDK issues, see the [developer documentation](https://wearables.developer.meta.com/docs/develop/) or the [discussions forum](https://github.com/facebook/meta-wearables-dat-ios/discussions).

## Credits

Forked from [sseanliu/VisionClaw](https://github.com/sseanliu/VisionClaw). Extended with OpenAI Realtime support, Cloudflare Tunnel remote access, background audio, and improved tool-calling prompts.

## License

This source code is licensed under the license found in the [LICENSE](LICENSE) file in the root directory of this source tree.
