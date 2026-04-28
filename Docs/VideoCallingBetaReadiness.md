# Prime Messaging Video Calling T5 (Beta Readiness)

## Scope
- Цель T5: дать repeatable матрицу тестирования и минимально достаточные метрики для быстрого triage инцидентов у тестеров.

## Device / OS Matrix
- iPhone 11 / iOS 16.x
- iPhone 13 / iOS 17.x
- iPhone 14 Pro / iOS 18.x
- iPhone 15 Pro / iOS 18.x
- iPhone SE (3rd gen) / iOS 17.x

## Network Matrix
- Wi-Fi (одна сеть)
- Wi-Fi (разные сети)
- LTE/5G <-> Wi-Fi handoff во время активного звонка
- Плохая сеть (packet loss / unstable link)

## Core Scenarios
1. Outgoing audio-only call.
2. Incoming audio-only call.
3. Answer from in-app screen.
4. Answer from system CallKit UI (lock screen / Dynamic Island).
5. Toggle video ON/OFF у caller.
6. Toggle video ON/OFF у callee.
7. Mute/unmute локального микрофона.
8. Speaker ON/OFF.
9. AirPods connect/disconnect во время звонка.
10. Background/foreground transitions.
11. Lock screen while call is active.
12. Call end from caller and from callee.

## Reliability Scenarios
1. Force-quit app, then incoming call delivery behavior.
2. Recover after route changes (receiver/speaker/Bluetooth).
3. Weak network fallback: video should degrade to audio when ICE is unstable.
4. Repeated call attempts (5-10 подряд) without app restart.

## Must-pass Acceptance
- Двусторонний звук стабилен.
- Видео включается/выключается без зависаний.
- System answer path не ломает медиа.
- Нет ложного `connected` без реального медиа.
- При плохой сети видео деградирует, аудио продолжает работать.

## Logs To Capture On Failure
- `webrtc.connection:*`
- `webrtc.ice:*`
- `webrtc.answer.*`
- `audio.route.*`
- `audio.session.snapshot.*`
- `video.profile.selected`
- `video.degrade.*`
- `metrics.call.summary`

## Triage Priority
1. P0: no audio either direction.
2. P1: system answer path has no media.
3. P1: crash / hard freeze.
4. P2: delayed video toggle / degraded quality.
5. P3: cosmetic UI issues without media regression.
